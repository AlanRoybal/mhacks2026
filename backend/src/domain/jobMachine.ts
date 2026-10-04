// The job state machine. Pure: no I/O, no clock, no randomness. Every job change goes through
// transition(), which either returns the next state plus side effects, or throws TransitionError.
//
// Invariants:
// - OFFERED  <=> currentOffer is set. Declines and expiries go back to FUNDED and ask for the next offer.
// - Money only moves through the "payout" and "refund" effects, which only these transitions emit,
//   and every non-terminal state has a timer or a user action that leads out of it.
// - Timer events re-check that they are due, so a stale timer is rejected instead of acting.
//   A timer that fires early is rejected as "too_early" and rescheduled by the caller.

import type { Effect, JobEvent, PushTemplate } from "./events.js";
import { haversineKm } from "./geo.js";
import { rematchDelaySec, type Rules } from "./rules.js";
import type { Actor, GradeDecision, Job, JobState } from "./types.js";

export type TransitionErrorCode =
  | "invalid_transition"
  | "forbidden"
  | "offer_not_current"
  | "offer_expired"
  | "not_enough_time"
  | "location_required"
  | "too_far"
  | "deadline_passed"
  | "window_closed"
  | "too_early"
  | "already_done"
  | "bad_request";

export class TransitionError extends Error {
  constructor(
    readonly code: TransitionErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "TransitionError";
  }
}

export interface TransitionContext {
  now: Date;
  actor: Actor;
  rules: Rules;
}

export interface TransitionResult {
  to: JobState;
  patch: Partial<Job>;
  effects: Effect[];
}

function fail(code: TransitionErrorCode, message: string): never {
  throw new TransitionError(code, message);
}

function requireState(job: Job, ev: JobEvent, ...allowed: JobState[]): void {
  if (!allowed.includes(job.state)) fail("invalid_transition", `${ev.type} is not allowed while the job is ${job.state}`);
}

function requireUser(ctx: TransitionContext, userId: string | undefined, who: string): string {
  if (ctx.actor.kind !== "user" || !userId || ctx.actor.userId !== userId) fail("forbidden", `Only the ${who} can do this`);
  return userId;
}

function requireSystem(ctx: TransitionContext, ev: JobEvent): void {
  if (ctx.actor.kind !== "system") fail("forbidden", `${ev.type} can only come from the platform`);
}

function requireDue(ctx: TransitionContext, dueMs: number, what: string): void {
  if (!Number.isFinite(dueMs)) fail("invalid_transition", `${what} has no due time`);
  if (ctx.now.getTime() < dueMs) fail("too_early", `${what} is not due yet`);
}

function currentOffer(job: Job, offerId: string): NonNullable<Job["currentOffer"]> {
  const offer = job.currentOffer;
  if (job.state !== "OFFERED" || !offer || offer.offerId !== offerId) {
    fail("offer_not_current", "This offer is no longer available");
  }
  return offer;
}

function pastDeadline(job: Job, now: Date): boolean {
  return now.getTime() >= Date.parse(job.deadline);
}

// Enough time left before the deadline to actually do the work.
function hasTimeLeft(job: Job, now: Date): boolean {
  return now.getTime() + job.estMinutes * 60_000 <= Date.parse(job.deadline);
}

const addSeconds = (d: Date, s: number) => new Date(d.getTime() + s * 1000).toISOString();
const isFiniteLatLng = (p: { lat: number; lng: number }) => Number.isFinite(p.lat) && Number.isFinite(p.lng);

function push(to: string, template: PushTemplate, offerId?: string): Effect {
  return offerId ? { kind: "push", to, template, offerId } : { kind: "push", to, template };
}

function release(job: Job, patch: Partial<Job>, now: string, extra: Effect[] = []): TransitionResult {
  const effects: Effect[] = [{ kind: "payout" }, ...extra];
  if (job.workerId) effects.push({ kind: "stats", userId: job.workerId, delta: { jobsCompleted: 1 } });
  return { to: "RELEASED", patch: { ...patch, closedAt: now }, effects };
}

function refundFailedWork(job: Job, patch: Partial<Job>, now: string, extra: Effect[] = []): TransitionResult {
  const effects: Effect[] = [{ kind: "refund" }, ...extra];
  if (job.workerId) effects.push({ kind: "stats", userId: job.workerId, delta: { jobsFailed: 1 } });
  return { to: "REFUNDED", patch: { ...patch, closedAt: now }, effects };
}

// A person has to decide: the AI was unsure, retries ran out, or grading never finished.
function needsPosterDecision(job: Job, ctx: TransitionContext, proofId: string, decision: GradeDecision, summary: string, failedAttempts: number): TransitionResult {
  const windowEndsAt = addSeconds(ctx.now, ctx.rules.posterDecisionWindowSec);
  const effects: Effect[] = [push(job.posterId, "proof_needs_decision"), { kind: "schedule", timer: "review_window", at: windowEndsAt }];
  if (job.workerId) effects.push(push(job.workerId, "proof_escalated"));
  return {
    to: "IN_REVIEW",
    patch: { failedAttempts, review: { proofId, decision, summary, requiresPosterAction: true, windowEndsAt } },
    effects,
  };
}

function openDispute(job: Job, ctx: TransitionContext, dispute: NonNullable<Job["dispute"]>, notify: string[]): TransitionResult {
  return {
    to: "DISPUTED",
    patch: { dispute },
    effects: [
      ...notify.map((userId) => push(userId, "disputed")),
      { kind: "schedule", timer: "dispute_timeout", at: addSeconds(ctx.now, ctx.rules.disputeWindowSec) },
    ],
  };
}

export function transition(job: Job, ev: JobEvent, ctx: TransitionContext): TransitionResult {
  const now = ctx.now.toISOString();

  switch (ev.type) {
    case "FUND_CONFIRMED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "DRAFT");
      if (ev.amountCents !== job.totalCents) fail("bad_request", `Payment of ${ev.amountCents} does not match the job total ${job.totalCents}`);
      if (job.payment.paymentIntentId && ev.paymentIntentId && ev.paymentIntentId !== job.payment.paymentIntentId) {
        fail("bad_request", "This payment does not belong to the job's checkout");
      }
      return {
        to: "FUNDED",
        patch: {
          fundedAt: now,
          matchRounds: job.matchRounds + 1,
          payment: {
            ...job.payment,
            paymentIntentId: ev.paymentIntentId ?? job.payment.paymentIntentId,
            chargeId: ev.chargeId ?? job.payment.chargeId,
          },
        },
        effects: [{ kind: "match" }, { kind: "schedule", timer: "deadline", at: job.deadline }],
      };
    }

    case "OFFER_SENT": {
      requireSystem(ctx, ev);
      requireState(job, ev, "FUNDED");
      if (ev.workerId === job.posterId || job.excludedWorkerIds.includes(ev.workerId)) {
        fail("bad_request", "This worker cannot be offered this job");
      }
      if (!hasTimeLeft(job, ctx.now)) fail("not_enough_time", "Not enough time left before the deadline");
      return {
        to: "OFFERED",
        patch: { currentOffer: { offerId: ev.offerId, workerId: ev.workerId, expiresAt: ev.expiresAt } },
        effects: [
          { kind: "offer.status", offerId: ev.offerId, status: "sent" },
          push(ev.workerId, "offer", ev.offerId),
          { kind: "schedule", timer: "offer_expire", at: ev.expiresAt, offerId: ev.offerId },
          { kind: "stats", userId: ev.workerId, delta: { offersReceived: 1 } },
        ],
      };
    }

    case "OFFER_DECLINED":
    case "OFFER_EXPIRED": {
      const offer = currentOffer(job, ev.offerId);
      const declined = ev.type === "OFFER_DECLINED";
      if (declined) {
        requireUser(ctx, offer.workerId, "offered worker");
      } else {
        requireSystem(ctx, ev);
        requireDue(ctx, Date.parse(offer.expiresAt), "The offer expiry");
      }
      return {
        to: "FUNDED",
        patch: { currentOffer: undefined, excludedWorkerIds: [...job.excludedWorkerIds, offer.workerId] },
        effects: [
          { kind: "offer.status", offerId: offer.offerId, status: declined ? "declined" : "expired" },
          { kind: "stats", userId: offer.workerId, delta: declined ? { offersDeclined: 1 } : { offersExpired: 1 } },
          { kind: "offer.next" },
        ],
      };
    }

    case "CANDIDATES_EXHAUSTED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "FUNDED");
      if (ev.round !== job.matchRounds || job.exhaustedRound === ev.round) fail("invalid_transition", "This matching round was already handled");
      const effects: Effect[] = [];
      const retryAt = addSeconds(ctx.now, rematchDelaySec(ctx.rules, job.matchRounds));
      if (Date.parse(retryAt) < Date.parse(job.deadline)) {
        effects.push({ kind: "schedule", timer: "rematch", at: retryAt, round: job.matchRounds });
      }
      if (job.matchRounds === 1) effects.push(push(job.posterId, "no_match_yet"));
      return { to: "FUNDED", patch: { exhaustedRound: ev.round }, effects };
    }

    case "REMATCH": {
      requireSystem(ctx, ev);
      requireState(job, ev, "FUNDED");
      if (ev.round !== job.matchRounds) fail("invalid_transition", "A newer matching round already started");
      return { to: "FUNDED", patch: { matchRounds: job.matchRounds + 1 }, effects: [{ kind: "match" }] };
    }

    case "ACCEPT": {
      // A second tap by the worker who already won is not "taken by someone else".
      if (job.state !== "OFFERED" && job.acceptedAt && ctx.actor.kind === "user" && ctx.actor.userId === job.workerId) {
        fail("already_done", "You already accepted this job");
      }
      const offer = currentOffer(job, ev.offerId);
      const workerId = requireUser(ctx, offer.workerId, "offered worker");
      if (ctx.now.getTime() >= Date.parse(offer.expiresAt)) fail("offer_expired", "This offer has expired");
      if (!hasTimeLeft(job, ctx.now)) fail("not_enough_time", "Not enough time left before the deadline");
      return {
        to: "ACCEPTED",
        patch: { workerId, currentOffer: undefined, acceptedAt: now },
        effects: [
          { kind: "offer.status", offerId: offer.offerId, status: "accepted" },
          { kind: "stats", userId: workerId, delta: { offersAccepted: 1 } },
          push(job.posterId, "offer_accepted"),
        ],
      };
    }

    case "CANCEL": {
      // US-18: only before a worker accepts. After that the worker can withdraw, or the deadline refunds.
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "FUNDED", "OFFERED");
      const effects: Effect[] = [{ kind: "refund" }];
      if (job.currentOffer) {
        effects.push({ kind: "offer.status", offerId: job.currentOffer.offerId, status: "canceled" });
        effects.push(push(job.currentOffer.workerId, "job_canceled"));
      }
      return { to: "REFUNDED", patch: { currentOffer: undefined, closedAt: now }, effects };
    }

    case "UPDATE_TERMS": {
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "FUNDED");
      if (ev.deadline === undefined && ev.radiusKm === undefined) fail("bad_request", "Nothing to update");
      const patch: Partial<Job> = { matchRounds: job.matchRounds + 1 };
      const effects: Effect[] = [{ kind: "match" }];
      if (ev.deadline !== undefined) {
        const deadline = Date.parse(ev.deadline);
        if (!Number.isFinite(deadline) || deadline <= ctx.now.getTime()) fail("bad_request", "The new deadline must be a future date");
        patch.deadline = new Date(deadline).toISOString();
        effects.push({ kind: "schedule", timer: "deadline", at: patch.deadline });
      }
      if (ev.radiusKm !== undefined) {
        if (job.remote) fail("bad_request", "Remote jobs have no radius");
        if (!Number.isFinite(ev.radiusKm) || ev.radiusKm <= 0 || ev.radiusKm > 100) fail("bad_request", "Radius must be between 0 and 100 km");
        patch.radiusKm = ev.radiusKm;
      }
      return { to: "FUNDED", patch, effects };
    }

    case "START": {
      requireUser(ctx, job.workerId, "assigned worker");
      requireState(job, ev, "ACCEPTED");
      if (pastDeadline(job, ctx.now)) fail("deadline_passed", "The job deadline has passed");
      if (!ev.captureKey.trim()) fail("bad_request", "Missing capture key");
      if (!job.remote) {
        if (!ev.at || !isFiniteLatLng(ev.at) || !job.location) fail("location_required", "Check in with your current location to start");
        const meters = Math.round(haversineKm(ev.at, job.location) * 1000);
        if (meters > ctx.rules.checkInRadiusM) {
          fail("too_far", `You are ${meters} m from the job. Check in within ${ctx.rules.checkInRadiusM} m.`);
        }
      }
      return { to: "IN_PROGRESS", patch: { startedAt: now, capture: { key: ev.captureKey, issuedAt: now } }, effects: [push(job.posterId, "job_started")] };
    }

    case "WITHDRAW": {
      const workerId = requireUser(ctx, job.workerId, "assigned worker");
      requireState(job, ev, "ACCEPTED", "IN_PROGRESS");
      return {
        to: "FUNDED",
        patch: {
          workerId: undefined,
          acceptedAt: undefined,
          startedAt: undefined,
          submittedAt: undefined,
          capture: undefined,
          latestProofId: undefined,
          failedAttempts: 0,
          excludedWorkerIds: [...job.excludedWorkerIds, workerId],
          matchRounds: job.matchRounds + 1,
        },
        effects: [
          { kind: "stats", userId: workerId, delta: { withdrawals: 1 } },
          push(job.posterId, "worker_withdrew"),
          { kind: "match" },
        ],
      };
    }

    case "SUBMIT": {
      requireUser(ctx, job.workerId, "assigned worker");
      requireState(job, ev, "IN_PROGRESS");
      if (pastDeadline(job, ctx.now)) fail("deadline_passed", "The job deadline has passed");
      if (ev.proofId === job.latestProofId) fail("already_done", "This proof was already submitted");
      return {
        to: "SUBMITTED",
        patch: { latestProofId: ev.proofId, submittedAt: now },
        effects: [
          { kind: "grade", proofId: ev.proofId },
          { kind: "schedule", timer: "grade_timeout", at: addSeconds(ctx.now, ctx.rules.gradeTimeoutSec), proofId: ev.proofId },
        ],
      };
    }

    case "GRADED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "SUBMITTED");
      if (ev.proofId !== job.latestProofId) fail("invalid_transition", "This grade is for an older submission");

      if (ev.decision === "pass") {
        const windowEndsAt = addSeconds(ctx.now, ctx.rules.reviewWindowSec);
        const effects: Effect[] = [push(job.posterId, "proof_ready"), { kind: "schedule", timer: "review_window", at: windowEndsAt }];
        if (job.workerId) effects.push(push(job.workerId, "proof_passed"));
        return {
          to: "IN_REVIEW",
          patch: { review: { proofId: ev.proofId, decision: "pass", summary: ev.summary, requiresPosterAction: false, windowEndsAt } },
          effects,
        };
      }

      const failedAttempts = ev.decision === "fail" ? job.failedAttempts + 1 : job.failedAttempts;
      if (ev.decision === "fail" && failedAttempts <= ctx.rules.maxRetries && !pastDeadline(job, ctx.now)) {
        const effects: Effect[] = [{ kind: "schedule", timer: "deadline", at: job.deadline }];
        if (job.workerId) effects.unshift(push(job.workerId, "proof_failed"));
        // The deadline timer may already have fired (and been ignored) while this proof was being graded.
        return { to: "IN_PROGRESS", patch: { failedAttempts }, effects };
      }
      return needsPosterDecision(job, ctx, ev.proofId, ev.decision, ev.summary, failedAttempts);
    }

    case "GRADE_TIMEOUT": {
      requireSystem(ctx, ev);
      requireState(job, ev, "SUBMITTED");
      if (ev.proofId !== job.latestProofId) fail("invalid_transition", "This timeout is for an older submission");
      requireDue(ctx, Date.parse(job.submittedAt ?? "") + ctx.rules.gradeTimeoutSec * 1000, "The grading timeout");
      return needsPosterDecision(job, ctx, ev.proofId, "unclear", "Automatic review did not finish in time. Please check the evidence yourself.", job.failedAttempts);
    }

    case "APPROVE": {
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "IN_REVIEW", "DISPUTED");
      if (job.state === "DISPUTED") {
        const resolution = { outcome: "release" as const, by: job.posterId, note: "The poster approved the work", at: now };
        return release(job, { resolution }, now, job.workerId ? [push(job.workerId, "resolved")] : []);
      }
      return release(job, {}, now);
    }

    case "REJECT": {
      // Only when the AI also found the work failing after the worker's retries. Otherwise: dispute.
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "IN_REVIEW");
      if (job.review?.decision !== "fail") fail("invalid_transition", "You can only reject work that failed review. Dispute it instead.");
      return refundFailedWork(job, {}, now, job.workerId ? [push(job.workerId, "work_rejected")] : []);
    }

    case "REVIEW_WINDOW_EXPIRED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "IN_REVIEW");
      const review = job.review;
      if (!review) fail("invalid_transition", "The job has no review");
      requireDue(ctx, Date.parse(review.windowEndsAt), "The review window");
      if (!review.requiresPosterAction) return release(job, {}, now);
      const notify = [job.posterId, ...(job.workerId ? [job.workerId] : [])];
      return openDispute(job, ctx, { reason: "The poster did not decide before the review window ended", openedBy: "system", openedAt: now }, notify);
    }

    case "DISPUTE": {
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "IN_REVIEW");
      if (job.review && ctx.now.getTime() >= Date.parse(job.review.windowEndsAt)) fail("window_closed", "The review window has closed");
      if (!job.checklist.some((item) => item.id === ev.itemId)) fail("bad_request", "Pick a checklist item to dispute");
      if (!ev.reason.trim()) fail("bad_request", "Explain what is wrong with this item");
      return openDispute(job, ctx, { itemId: ev.itemId, reason: ev.reason.trim(), openedBy: "poster", openedAt: now }, job.workerId ? [job.workerId] : []);
    }

    case "RESOLVE": {
      if (ctx.actor.kind !== "admin") fail("forbidden", "Only an admin can resolve disputes");
      if (ctx.actor.userId === job.posterId || ctx.actor.userId === job.workerId) fail("forbidden", "You can't resolve a dispute on your own job");
      requireState(job, ev, "DISPUTED");
      const resolution = { outcome: ev.outcome, by: ctx.actor.userId, note: ev.note, at: now };
      const notify: Effect[] = [push(job.posterId, "resolved")];
      if (job.workerId) notify.push(push(job.workerId, "resolved"));
      return ev.outcome === "release" ? release(job, { resolution }, now, notify) : refundFailedWork(job, { resolution }, now, notify);
    }

    case "DISPUTE_TIMEOUT": {
      // Nobody resolved it in time: the AI's assessment stands. Failed work is refunded; anything else is paid.
      requireSystem(ctx, ev);
      requireState(job, ev, "DISPUTED");
      if (!job.dispute) fail("invalid_transition", "The job has no dispute");
      requireDue(ctx, Date.parse(job.dispute.openedAt) + ctx.rules.disputeWindowSec * 1000, "The dispute window");
      const outcome = job.review?.decision === "fail" ? ("refund" as const) : ("release" as const);
      const resolution = { outcome, by: "system", note: "No decision before the dispute window ended; the AI assessment stands", at: now };
      const notify: Effect[] = [push(job.posterId, "resolved")];
      if (job.workerId) notify.push(push(job.workerId, "resolved"));
      return outcome === "release" ? release(job, { resolution }, now, notify) : refundFailedWork(job, { resolution }, now, notify);
    }

    case "DEADLINE_PASSED": {
      requireSystem(ctx, ev);
      requireDue(ctx, Date.parse(job.deadline), "The deadline");
      if (job.state === "FUNDED" || job.state === "OFFERED") {
        const effects: Effect[] = [{ kind: "refund" }, push(job.posterId, "unmatched_refund")];
        if (job.currentOffer) {
          effects.push({ kind: "offer.status", offerId: job.currentOffer.offerId, status: "canceled" });
          effects.push(push(job.currentOffer.workerId, "offer_closed"));
        }
        return { to: "REFUNDED", patch: { currentOffer: undefined, closedAt: now }, effects };
      }
      if (job.state === "ACCEPTED" || job.state === "IN_PROGRESS") {
        const effects: Effect[] = [push(job.posterId, "deadline_missed")];
        if (job.workerId) effects.push(push(job.workerId, "deadline_missed"));
        return refundFailedWork(job, {}, now, effects);
      }
      // Submitted work is reviewed even if the deadline passes during grading or review.
      return fail("invalid_transition", `Deadline does not apply while the job is ${job.state}`);
    }

    case "PAYOUT_CONFIRMED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "RELEASED");
      if (job.payment.transferId) fail("already_done", "Payout already recorded");
      return {
        to: "RELEASED",
        patch: { payment: { ...job.payment, transferId: ev.transferId } },
        effects: job.workerId ? [push(job.workerId, "paid")] : [],
      };
    }

    case "REFUND_CONFIRMED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "REFUNDED");
      if (job.payment.refundId) fail("already_done", "Refund already recorded");
      return {
        to: "REFUNDED",
        patch: { payment: { ...job.payment, refundId: ev.refundId } },
        effects: [push(job.posterId, "refunded")],
      };
    }

    case "RATE": {
      requireState(job, ev, "RELEASED", "REFUNDED");
      if (!job.workerId) fail("invalid_transition", "Nobody worked on this job");
      if (!Number.isInteger(ev.stars) || ev.stars < 1 || ev.stars > 5) fail("bad_request", "Stars must be 1 to 5");
      const rating = { stars: ev.stars, comment: ev.comment?.trim() || undefined, at: now };
      if (ctx.actor.kind === "user" && ctx.actor.userId === job.posterId) {
        if (job.ratings.byPoster) fail("already_done", "You already rated this job");
        return {
          to: job.state,
          patch: { ratings: { ...job.ratings, byPoster: rating } },
          effects: [{ kind: "stats", userId: job.workerId, delta: { ratingSum: ev.stars, ratingCount: 1 } }],
        };
      }
      if (ctx.actor.kind === "user" && ctx.actor.userId === job.workerId) {
        if (job.ratings.byWorker) fail("already_done", "You already rated this job");
        return {
          to: job.state,
          patch: { ratings: { ...job.ratings, byWorker: rating } },
          effects: [{ kind: "stats", userId: job.posterId, delta: { posterRatingSum: ev.stars, posterRatingCount: 1 } }],
        };
      }
      return fail("forbidden", "Only the poster or the worker can rate this job");
    }
  }
}

export type JobAction =
  | "edit_checklist"
  | "fund"
  | "delete"
  | "cancel"
  | "update_terms"
  | "accept"
  | "decline"
  | "start"
  | "withdraw"
  | "submit_proof"
  | "approve"
  | "reject"
  | "dispute"
  | "resolve"
  | "rate";

// What the viewer can do right now. Drives the buttons on the adaptive job detail screen.
export function allowedActions(job: Job, viewer: { userId: string; isAdmin?: boolean }, now: Date): JobAction[] {
  const actions: JobAction[] = [];
  const isPoster = viewer.userId === job.posterId;
  const isWorker = viewer.userId === job.workerId;
  const closed = job.state === "RELEASED" || job.state === "REFUNDED";

  if (isPoster) {
    if (job.state === "DRAFT") actions.push("edit_checklist", "fund", "delete");
    if (job.state === "FUNDED") actions.push("update_terms");
    if (job.state === "FUNDED" || job.state === "OFFERED") actions.push("cancel");
    if (job.state === "IN_REVIEW") {
      actions.push("approve");
      if (job.review?.decision === "fail") actions.push("reject");
      if (job.review && now.getTime() < Date.parse(job.review.windowEndsAt)) actions.push("dispute");
    }
    if (job.state === "DISPUTED") actions.push("approve");
    if (closed && job.workerId && !job.ratings.byPoster) actions.push("rate");
  }
  if (job.state === "OFFERED" && job.currentOffer?.workerId === viewer.userId && now.getTime() < Date.parse(job.currentOffer.expiresAt)) {
    actions.push("accept", "decline");
  }
  if (isWorker) {
    if (job.state === "ACCEPTED") actions.push("start", "withdraw");
    if (job.state === "IN_PROGRESS") actions.push("submit_proof", "withdraw");
    if (closed && !job.ratings.byWorker) actions.push("rate");
  }
  if (viewer.isAdmin && job.state === "DISPUTED" && !isPoster && !isWorker) actions.push("resolve");
  return actions;
}
