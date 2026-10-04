// JSON shapes sent to the iOS app. The Job shape matches Bounty/Models/Job.swift on the iOS-B branch
// field for field; anything extra (allowedActions, offer, review, ...) is ignored by Swift's Codable
// until the app adds it, so new fields can ship without breaking older builds.
//
// Conventions: money in dollars (Decimal on iOS), distances in miles, dates as ISO-8601 without
// fractional seconds (works with JSONDecoder.dateDecodingStrategy = .iso8601).

import { fileUrl } from "../blobs/fileUrls.js";
import type { Deps } from "../deps.js";
import type { JobEventType, LedgerEvent } from "../domain/events.js";
import { allowedActions } from "../domain/jobMachine.js";
import { hourlyCents } from "../domain/money.js";
import { verificationPlan } from "../domain/verification.js";
import type { ChecklistItem, Job, Offer, Proof, User } from "../domain/types.js";
import { notFound } from "../lib/errors.js";
import { CONFIDENT } from "../services/grading.js";
import { photoGeofenceM } from "../services/proof.js";
import { jobRisk, type JobRisk } from "../services/risk.js";
import { reliability } from "../services/users.js";
import { isAdmin } from "./auth.js";

export const KM_PER_MILE = 1.609344;

export const wireDate = (iso: string | undefined | null): string | null => (iso ? new Date(iso).toISOString().replace(/\.\d{3}Z$/, "Z") : null);
export const dollars = (cents: number) => cents / 100;
export const kmToMiles = (km: number | undefined) => (km === undefined ? null : Math.round((km / KM_PER_MILE) * 10) / 10);
export const milesToKm = (miles: number) => miles * KM_PER_MILE;

export type JobRole = "poster" | "worker" | "offered" | "admin";

export function roleOf(deps: Deps, job: Job, viewer: User): JobRole | null {
  if (viewer.userId === job.posterId) return "poster";
  if (viewer.userId === job.workerId) return "worker";
  if (viewer.userId === job.currentOffer?.workerId) return "offered";
  if (isAdmin(deps, viewer)) return "admin";
  return null;
}

export function checklistWire(item: ChecklistItem) {
  const photo = item.evidenceType === "PHOTO";
  return {
    id: item.id,
    text: item.text,
    evidenceType: item.evidenceType,
    photoCount: photo ? (item.photoCount ?? 1) : null,
    required: item.required,
    beforeAfter: Boolean(item.beforeAfter),
    angleHint: item.angleHint ?? null,
  };
}

export function personWire(user: User | null, as: "worker" | "poster") {
  if (!user) return null;
  const sum = as === "worker" ? user.stats.ratingSum : user.stats.posterRatingSum;
  const count = as === "worker" ? user.stats.ratingCount : user.stats.posterRatingCount;
  return {
    id: user.userId,
    name: user.displayName,
    rating: count === 0 ? null : Math.round((sum / count) * 10) / 10,
    photoURL: user.photoUrl ?? null,
    reliability: as === "worker" ? Math.round(reliability(user.stats).score * 100) / 100 : null,
  };
}

export function proofWire(deps: Deps, proof: Proof) {
  const ids = [...new Set(proof.items.map((i) => i.checklistItemId))];
  const url = (key?: string) => (key ? fileUrl(deps.config, key) : null);
  return {
    id: proof.proofId,
    attempt: proof.attempt,
    submittedAt: wireDate(proof.createdAt),
    items: ids.map((checklistItemId) => {
      const items = proof.items.filter((i) => i.checklistItemId === checklistItemId);
      const photos = items.filter((i) => i.kind === "photo" && !i.frameOf);
      const byPhase = (phase: string) => photos.filter((p) => p.phase === phase).map((p) => url(p.blobKey)).filter(Boolean);
      const location = items.find((i) => i.kind === "location");
      return {
        checklistItemId,
        photoURLs: [...byPhase("before"), ...byPhase("single"), ...byPhase("after")],
        beforePhotoURLs: byPhase("before"),
        afterPhotoURLs: byPhase("after"),
        link: items.find((i) => i.kind === "link")?.url ?? null,
        fileURLs: items.filter((i) => i.kind === "file").map((i) => url(i.blobKey)).filter(Boolean),
        videoURLs: items.filter((i) => i.kind === "video").map((i) => url(i.blobKey)).filter(Boolean),
        checkedInAt: wireDate(location?.capturedAt),
        note: items.find((i) => i.note)?.note ?? null,
      };
    }),
    checks: proof.checks,
  };
}

export function verdictsWire(proof: Proof | null) {
  return (proof?.grade?.items ?? []).map((v) => ({
    checklistItemId: v.itemId,
    pass: v.verdict === "pass",
    verdict: v.verdict,
    confidence: v.confidence,
    explanation: v.reason,
  }));
}

function paymentStatus(job: Job): "unpaid" | "held" | "releasing" | "paid" | "refunding" | "refunded" {
  if (job.state === "DRAFT") return "unpaid";
  if (job.state === "RELEASED") return job.payment.transferId ? "paid" : "releasing";
  if (job.state === "REFUNDED") return job.payment.refundId ? "refunded" : "refunding";
  return "held";
}

// Caches users across a list so each person is loaded once.
export class WireContext {
  private readonly users = new Map<string, Promise<User | null>>();

  constructor(readonly deps: Deps) {}

  user(userId: string | undefined): Promise<User | null> {
    if (!userId) return Promise.resolve(null);
    let user = this.users.get(userId);
    if (!user) {
      user = this.deps.store.getUser(userId);
      this.users.set(userId, user);
    }
    return user;
  }
}

async function viewerOffer(deps: Deps, job: Job, viewer: User, role: JobRole): Promise<Offer | null> {
  if (role === "offered" && job.currentOffer) return deps.store.getOffer(job.currentOffer.offerId);
  if (role === "worker") {
    const offers = await deps.store.listOffersForJob(job.jobId);
    return offers.find((o) => o.workerId === viewer.userId && o.status === "accepted") ?? null;
  }
  return null;
}

export async function jobWire(ctx: WireContext, job: Job, viewer: User) {
  const deps = ctx.deps;
  const role = roleOf(deps, job, viewer);
  if (!role) throw notFound("Job");
  const now = deps.now();
  const [worker, poster, offer, proof] = await Promise.all([
    ctx.user(job.workerId),
    ctx.user(job.posterId),
    viewerOffer(deps, job, viewer, role),
    job.latestProofId && role !== "offered" ? deps.store.getProof(job.jobId, job.latestProofId) : Promise.resolve(null),
  ]);
  const isPoster = role === "poster" || role === "admin";
  // Only the assigned worker's app, and only while it can still capture proof.
  const showCaptureKey = role === "worker" && job.state === "IN_PROGRESS";

  return {
    // Fields in Job.swift
    id: job.jobId,
    title: job.title,
    description: job.description,
    category: job.category,
    location: job.location ? { latitude: job.location.lat, longitude: job.location.lng, address: job.location.address ?? "" } : null,
    deadline: wireDate(job.deadline),
    payAmount: dollars(job.bountyCents),
    currency: job.currency,
    posterPhotos: job.photos.map((key) => fileUrl(deps.config, key)),
    checklist: job.checklist.map(checklistWire),
    status: job.state,
    worker: personWire(worker, "worker"),
    proof: proof ? proofWire(deps, proof) : null,
    verdicts: verdictsWire(proof),
    reviewDeadline: job.state === "IN_REVIEW" ? wireDate(job.review?.windowEndsAt) : null,
    createdAt: wireDate(job.createdAt),
    matchReason: offer?.why ?? null,
    distanceMiles: kmToMiles(offer?.distanceKm),

    // Extensions
    myRole: role,
    allowedActions: allowedActions(job, { userId: viewer.userId, isAdmin: isAdmin(deps, viewer) }, now),
    poster: personWire(poster, "poster"),
    estMinutes: job.estMinutes,
    // What Bounty checks before paying, and what it records about the worker to do so. Shown to the
    // poster before funding and to workers before they accept.
    verification: verificationPlan(
      { remote: job.remote, address: job.location?.address, checklist: job.checklist },
      { checkInRadiusM: deps.config.rules.checkInRadiusM, photoRadiusM: photoGeofenceM(deps), confidence: CONFIDENT },
    ),
    // The escrow's risk (domain/risk.ts), for the poster and admins once the job holds money:
    // tier A-E, EL = PD x LGD x EAD, and the assigned worker's trust score.
    risk: isPoster && job.state !== "DRAFT" ? riskWire(await jobRisk(deps, job)) : null,
    // In-person jobs: how far from the address the worker was when they started, and how accurate
    // that fix was. Distance only; the worker's coordinates aren't shared.
    startCheck:
      (isPoster || role === "worker") && job.startCheck
        ? { distanceM: job.startCheck.distanceM, accuracyM: job.startCheck.accuracyM ?? null, at: wireDate(job.startCheck.at) }
        : null,
    radiusMiles: job.remote ? null : kmToMiles(job.radiusKm),
    feeAmount: isPoster ? dollars(job.feeCents) : null,
    totalAmount: isPoster ? dollars(job.totalCents) : null,
    flags: isPoster ? job.flags : [],
    offer:
      role === "offered" && job.currentOffer && offer
        ? {
            id: offer.offerId,
            expiresAt: wireDate(job.currentOffer.expiresAt),
            estMinutes: offer.estMinutes,
            hourlyRate: dollars(hourlyCents(job.bountyCents, offer.estMinutes)),
            travelMinutes: offer.travelMinutes ?? null,
            fit: offer.fit,
          }
        : isPoster && job.currentOffer
          ? { id: job.currentOffer.offerId, expiresAt: wireDate(job.currentOffer.expiresAt) }
          : null,
    captureKey: showCaptureKey ? (job.capture?.key ?? null) : null,
    attempts: { failed: job.failedAttempts, maxRetries: deps.config.rules.maxRetries },
    review: job.review
      ? {
          decision: job.review.decision,
          summary: job.review.summary,
          requiresPosterAction: job.review.requiresPosterAction,
          windowEndsAt: wireDate(job.review.windowEndsAt),
        }
      : null,
    dispute: job.dispute ? { ...job.dispute, openedAt: wireDate(job.dispute.openedAt) } : null,
    resolution: job.resolution ? { ...job.resolution, at: wireDate(job.resolution.at) } : null,
    payment: { status: paymentStatus(job) },
    ratings: {
      byPoster: job.ratings.byPoster ? { stars: job.ratings.byPoster.stars, comment: job.ratings.byPoster.comment ?? null } : null,
      byWorker: job.ratings.byWorker ? { stars: job.ratings.byWorker.stars, comment: job.ratings.byWorker.comment ?? null } : null,
    },
    updatedAt: wireDate(job.updatedAt),
  };
}

const LABELS: Record<JobEventType | "CREATED", (e: LedgerEvent) => string> = {
  CREATED: () => "Job created",
  FUND_CONFIRMED: () => "Payment received; job is funded",
  OFFER_SENT: () => "Offered to a matching worker",
  OFFER_DECLINED: () => "Worker declined; trying the next match",
  OFFER_EXPIRED: () => "Offer expired; trying the next match",
  CANDIDATES_EXHAUSTED: () => "No available workers right now; will search again",
  REMATCH: () => "Searching for workers again",
  ACCEPT: () => "Worker accepted",
  CANCEL: () => "Poster canceled the job",
  UPDATE_TERMS: () => "Poster updated the deadline or radius",
  START: () => "Worker checked in and started",
  WITHDRAW: () => "Worker withdrew; finding someone else",
  SUBMIT: () => "Proof submitted",
  GRADED: (e) => (e.event?.type === "GRADED" ? `AI review: ${e.event.decision === "pass" ? "passed" : e.event.decision === "fail" ? "did not pass" : "unsure"}` : "AI review finished"),
  GRADE_TIMEOUT: () => "AI review took too long; sent to the poster",
  APPROVE: () => "Poster approved the work",
  REJECT: () => "Poster rejected the work",
  REVIEW_WINDOW_EXPIRED: (e) => (e.to === "RELEASED" ? "Review window ended; payment released" : "Review window ended without a decision"),
  DISPUTE: () => "Poster opened a dispute",
  RESOLVE: (e) => (e.to === "RELEASED" ? "Dispute resolved for the worker" : "Dispute resolved for the poster"),
  DISPUTE_TIMEOUT: (e) => (e.to === "RELEASED" ? "Dispute closed; payment released" : "Dispute closed; poster refunded"),
  DEADLINE_PASSED: () => "Deadline passed; poster refunded",
  PAYOUT_CONFIRMED: () => "Payment sent to the worker",
  REFUND_CONFIRMED: () => "Refund sent to the poster",
  RATE: () => "Rating left",
};

export function timelineWire(job: Job, viewer: User, ledger: LedgerEvent[]) {
  return ledger.map((e) => {
    const actor =
      e.actor.kind === "system"
        ? "platform"
        : e.actor.kind === "admin"
          ? "admin"
          : e.actor.userId === viewer.userId
            ? "you"
            : e.actor.userId === job.posterId
              ? "poster"
              : "worker";
    return { seq: e.seq, type: e.type, status: e.to, from: e.from, label: LABELS[e.type](e), actor, at: wireDate(e.at) };
  });
}

export function riskWire(risk: JobRisk) {
  const pct = (x: number) => Math.round(x * 1000) / 1000;
  return {
    tier: risk.tier,
    rail: risk.rail,
    exposure: dollars(risk.exposureCents),
    probabilityOfLoss: pct(risk.pd),
    lossGivenDefault: pct(risk.lgd),
    expectedLoss: dollars(risk.expectedLossCents),
    worker: risk.worker ? { trust: pct(risk.worker.trust), conservative: pct(risk.worker.lower), ratedJobs: risk.worker.ratedJobs } : null,
    posterDisputeProbability: pct(risk.posterDispute),
  };
}
