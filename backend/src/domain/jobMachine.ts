// The job state machine. Pure: no I/O, no clock, no randomness. Every job change goes through
// transition(), which either returns the next state plus side effects, or throws TransitionError.
//
// Invariants:
// - OFFERED  <=> currentOffer is set. Declines and expiries go back to FUNDED and ask for the next offer.
// - Money only moves through the "payout" and "refund" effects, which only these transitions emit.
// - Timer events re-check that they are still due, so a stale timer is rejected instead of acting.

import type { Effect, JobEvent, PushTemplate } from "./events.js";
import { haversineKm } from "./geo.js";
import type { Rules } from "./rules.js";
import type { Actor, Job, JobState } from "./types.js";

export type TransitionErrorCode =
  | "invalid_transition"
  | "forbidden"
  | "offer_not_current"
  | "offer_expired"
  | "location_required"
  | "too_far"
  | "deadline_passed"
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

function requireDue(ctx: TransitionContext, dueIso: string, what: string): void {
  if (ctx.now.getTime() < Date.parse(dueIso) - ctx.rules.timerToleranceMs) fail("too_early", `${what} is not due yet`);
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

const addSeconds = (d: Date, s: number) => new Date(d.getTime() + s * 1000).toISOString();

function push(to: string, template: PushTemplate, offerId?: string): Effect {
  return offerId ? { kind: "push", to, template, offerId } : { kind: "push", to, template };
}

function release(job: Job, patch: Partial<Job>, now: string, extra: Effect[] = []): TransitionResult {
  const effects: Effect[] = [{ kind: "payout" }, ...extra];
  if (job.workerId) effects.push({ kind: "stats", userId: job.workerId, delta: { jobsCompleted: 1 } });
  return { to: "RELEASED", patch: { ...patch, closedAt: now }, effects };
}

export function transition(job: Job, ev: JobEvent, ctx: TransitionContext): TransitionResult {
  const now = ctx.now.toISOString();

  switch (ev.type) {
    case "FUND_CONFIRMED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "DRAFT");
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
        requireDue(ctx, offer.expiresAt, "The offer expiry");
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
      const effects: Effect[] = [];
      const retryAt = addSeconds(ctx.now, ctx.rules.rematchDelaySec);
      if (job.matchRounds < ctx.rules.maxMatchRounds && Date.parse(retryAt) < Date.parse(job.deadline)) {
        effects.push({ kind: "schedule", timer: "rematch", at: retryAt, round: job.matchRounds });
      }
      if (job.matchRounds === 1) effects.push(push(job.posterId, "no_match_yet"));
      return { to: "FUNDED", patch: {}, effects };
    }

    case "REMATCH": {
      requireSystem(ctx, ev);
      requireState(job, ev, "FUNDED");
      if (ev.round !== job.matchRounds) fail("invalid_transition", "A newer matching round already started");
      return { to: "FUNDED", patch: { matchRounds: job.matchRounds + 1 }, effects: [{ kind: "match" }] };
    }

    case "ACCEPT": {
      const offer = currentOffer(job, ev.offerId);
      const workerId = requireUser(ctx, offer.workerId, "offered worker");
      if (ctx.now.getTime() >= Date.parse(offer.expiresAt)) fail("offer_expired", "This offer has expired");
      if (pastDeadline(job, ctx.now)) fail("deadline_passed", "The job deadline has passed");
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
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "FUNDED", "OFFERED", "ACCEPTED");
      const effects: Effect[] = [{ kind: "refund" }];
      if (job.currentOffer) {
        effects.push({ kind: "offer.status", offerId: job.currentOffer.offerId, status: "canceled" });
        effects.push(push(job.currentOffer.workerId, "job_canceled"));
      }
      if (job.workerId) effects.push(push(job.workerId, "job_canceled"));
      return { to: "REFUNDED", patch: { currentOffer: undefined, closedAt: now }, effects };
    }

    case "UPDATE_TERMS": {
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "FUNDED");
      if (ev.deadline === undefined && ev.radiusKm === undefined) fail("bad_request", "Nothing to update");
      const patch: Partial<Job> = { matchRounds: job.matchRounds + 1 };
      const effects: Effect[] = [{ kind: "match" }];
      if (ev.deadline !== undefined) {
        if (Date.parse(ev.deadline) <= ctx.now.getTime()) fail("bad_request", "The new deadline must be in the future");
        patch.deadline = ev.deadline;
        effects.push({ kind: "schedule", timer: "deadline", at: ev.deadline });
      }
      if (ev.radiusKm !== undefined) {
        if (job.remote) fail("bad_request", "Remote jobs have no radius");
        patch.radiusKm = ev.radiusKm;
      }
      return { to: "FUNDED", patch, effects };
    }

    case "START": {
      requireUser(ctx, job.workerId, "assigned worker");
      requireState(job, ev, "ACCEPTED");
      if (pastDeadline(job, ctx.now)) fail("deadline_passed", "The job deadline has passed");
      if (!job.remote) {
        if (!ev.at || !job.location) fail("location_required", "Check in with your current location to start");
        const meters = Math.round(haversineKm(ev.at, job.location) * 1000);
        if (meters > ctx.rules.checkInRadiusM) {
          fail("too_far", `You are ${meters} m from the job. Check in within ${ctx.rules.checkInRadiusM} m.`);
        }
      }
      return { to: "IN_PROGRESS", patch: { startedAt: now, challenge: { code: ev.code, issuedAt: now } }, effects: [] };
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
          challenge: undefined,
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
      return {
        to: "SUBMITTED",
        patch: { latestProofId: ev.proofId, submittedAt: now },
        effects: [{ kind: "grade", proofId: ev.proofId }],
      };
    }

    case "GRADED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "SUBMITTED");
      if (ev.proofId !== job.latestProofId) fail("invalid_transition", "This grade is for an older submission");
      const workerId = job.workerId ?? "";

      if (ev.decision === "pass") {
        const windowEndsAt = addSeconds(ctx.now, ctx.rules.reviewWindowSec);
        return {
          to: "IN_REVIEW",
          patch: { review: { proofId: ev.proofId, decision: "pass", summary: ev.summary, requiresPosterAction: false, windowEndsAt } },
          effects: [
            push(job.posterId, "proof_ready"),
            push(workerId, "proof_passed"),
            { kind: "schedule", timer: "review_window", at: windowEndsAt },
          ],
        };
      }

      const failedAttempts = ev.decision === "fail" ? job.failedAttempts + 1 : job.failedAttempts;
      if (ev.decision === "fail" && failedAttempts <= ctx.rules.maxRetries && !pastDeadline(job, ctx.now)) {
        return { to: "IN_PROGRESS", patch: { failedAttempts }, effects: [push(workerId, "proof_failed")] };
      }

      // Unclear, or out of retries: a person has to decide. No auto-release.
      const windowEndsAt = addSeconds(ctx.now, ctx.rules.posterDecisionWindowSec);
      return {
        to: "IN_REVIEW",
        patch: {
          failedAttempts,
          review: { proofId: ev.proofId, decision: ev.decision, summary: ev.summary, requiresPosterAction: true, windowEndsAt },
        },
        effects: [
          push(job.posterId, "proof_needs_decision"),
          push(workerId, "proof_escalated"),
          { kind: "schedule", timer: "review_window", at: windowEndsAt },
        ],
      };
    }

    case "APPROVE": {
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "IN_REVIEW");
      return release(job, {}, now);
    }

    case "REVIEW_WINDOW_EXPIRED": {
      requireSystem(ctx, ev);
      requireState(job, ev, "IN_REVIEW");
      const review = job.review;
      if (!review) fail("invalid_transition", "The job has no review");
      requireDue(ctx, review.windowEndsAt, "The review window");
      if (!review.requiresPosterAction) return release(job, {}, now);
      const effects: Effect[] = [push(job.posterId, "disputed")];
      if (job.workerId) effects.push(push(job.workerId, "disputed"));
      return {
        to: "DISPUTED",
        patch: { dispute: { reason: "The poster did not decide before the review window ended", openedBy: "system", openedAt: now } },
        effects,
      };
    }

    case "DISPUTE": {
      requireUser(ctx, job.posterId, "poster");
      requireState(job, ev, "IN_REVIEW");
      if (!job.checklist.some((item) => item.id === ev.itemId)) fail("bad_request", "Pick a checklist item to dispute");
      if (!ev.reason.trim()) fail("bad_request", "Explain what is wrong with this item");
      const effects: Effect[] = job.workerId ? [push(job.workerId, "disputed")] : [];
      return {
        to: "DISPUTED",
        patch: { dispute: { itemId: ev.itemId, reason: ev.reason.trim(), openedBy: "poster", openedAt: now } },
        effects,
      };
    }

    case "RESOLVE": {
      if (ctx.actor.kind !== "admin") fail("forbidden", "Only an admin can resolve disputes");
      requireState(job, ev, "DISPUTED");
      const resolution = { outcome: ev.outcome, by: ctx.actor.userId, note: ev.note, at: now };
      const notify: Effect[] = [push(job.posterId, "resolved")];
      if (job.workerId) notify.push(push(job.workerId, "resolved"));
      if (ev.outcome === "release") return release(job, { resolution }, now, notify);
      const effects: Effect[] = [{ kind: "refund" }, ...notify];
      if (job.workerId) effects.push({ kind: "stats", userId: job.workerId, delta: { jobsFailed: 1 } });
      return { to: "REFUNDED", patch: { resolution, closedAt: now }, effects };
    }

    case "DEADLINE_PASSED": {
      requireSystem(ctx, ev);
      requireDue(ctx, job.deadline, "The deadline");
      if (job.state === "FUNDED" || job.state === "OFFERED") {
        const effects: Effect[] = [{ kind: "refund" }, push(job.posterId, "unmatched_refund")];
        if (job.currentOffer) effects.push({ kind: "offer.status", offerId: job.currentOffer.offerId, status: "canceled" });
        return { to: "REFUNDED", patch: { currentOffer: undefined, closedAt: now }, effects };
      }
      if (job.state === "ACCEPTED" || job.state === "IN_PROGRESS") {
        const effects: Effect[] = [{ kind: "refund" }, push(job.posterId, "deadline_missed")];
        if (job.workerId) {
          effects.push(push(job.workerId, "deadline_missed"));
          effects.push({ kind: "stats", userId: job.workerId, delta: { jobsFailed: 1 } });
        }
        return { to: "REFUNDED", patch: { closedAt: now }, effects };
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
    if (job.state === "FUNDED" || job.state === "OFFERED" || job.state === "ACCEPTED") actions.push("cancel");
    if (job.state === "IN_REVIEW") actions.push("approve", "dispute");
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
  if (viewer.isAdmin && job.state === "DISPUTED") actions.push("resolve");
  return actions;
}
