import assert from "node:assert/strict";
import { describe, test } from "node:test";
import type { Effect, JobEvent } from "./events.js";
import { allowedActions, transition, TransitionError, type TransitionErrorCode } from "./jobMachine.js";
import { rulesFor } from "./rules.js";
import type { Actor, Job } from "./types.js";

const rules = rulesFor(false);
const T0 = new Date("2026-10-04T15:00:00Z");
const at = (minutes: number) => new Date(T0.getTime() + minutes * 60_000);
const iso = (minutes: number) => at(minutes).toISOString();

const POSTER: Actor = { kind: "user", userId: "poster" };
const WORKER: Actor = { kind: "user", userId: "worker" };
const OTHER: Actor = { kind: "user", userId: "other" };
const SYSTEM: Actor = { kind: "system", source: "test" };
const ADMIN: Actor = { kind: "admin", userId: "admin" };

const SITE = { lat: 42.2808, lng: -83.743 };

function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    jobId: "job1",
    posterId: "poster",
    title: "Sketch a logo",
    description: "Coffee shop logo on paper",
    category: "design",
    photos: [],
    remote: false,
    location: SITE,
    radiusKm: 5,
    deadline: iso(24 * 60),
    estMinutes: 15,
    bountyCents: 1500,
    feeCents: 150,
    totalCents: 1650,
    rail: "fake",
    state: "DRAFT",
    version: 1,
    checklist: [{ id: "c1", text: "Logo is visible", evidence: "photo", required: true }],
    excludedWorkerIds: [],
    failedAttempts: 0,
    payment: {},
    ratings: {},
    matchRounds: 0,
    createdAt: iso(0),
    updatedAt: iso(0),
    ...overrides,
  };
}

// Applies the result the same way the job service does.
function apply(job: Job, ev: JobEvent, actor: Actor, now = at(1)): { job: Job; effects: Effect[] } {
  const r = transition(job, ev, { now, actor, rules });
  return { job: { ...job, ...r.patch, state: r.to, version: job.version + 1 }, effects: r.effects };
}

function rejects(job: Job, ev: JobEvent, actor: Actor, code: TransitionErrorCode, now = at(1)) {
  assert.throws(
    () => transition(job, ev, { now, actor, rules }),
    (e: unknown) => e instanceof TransitionError && e.code === code,
  );
}

const kinds = (effects: Effect[]) => effects.map((e) => (e.kind === "push" ? `push:${e.to}:${e.template}` : e.kind));

function offered(): Job {
  return apply(makeJob({ state: "FUNDED", matchRounds: 1 }), { type: "OFFER_SENT", offerId: "o1", workerId: "worker", expiresAt: iso(2) }, SYSTEM).job;
}
const accepted = () => apply(offered(), { type: "ACCEPT", offerId: "o1" }, WORKER).job;
const inProgress = () => apply(accepted(), { type: "START", code: "ABC-DEF", at: SITE }, WORKER).job;
const submitted = () => apply(inProgress(), { type: "SUBMIT", proofId: "p1" }, WORKER).job;

describe("funding and matching", () => {
  test("fund confirmation starts matching and the deadline timer", () => {
    const { job, effects } = apply(makeJob(), { type: "FUND_CONFIRMED", paymentIntentId: "pi_1", chargeId: "ch_1" }, SYSTEM);
    assert.equal(job.state, "FUNDED");
    assert.equal(job.matchRounds, 1);
    assert.equal(job.payment.chargeId, "ch_1");
    assert.deepEqual(kinds(effects), ["match", "schedule"]);
  });

  test("only the platform can confirm funding, and only once", () => {
    rejects(makeJob(), { type: "FUND_CONFIRMED" }, POSTER, "forbidden");
    rejects(makeJob({ state: "FUNDED" }), { type: "FUND_CONFIRMED" }, SYSTEM, "invalid_transition");
  });

  test("an offer moves the job to OFFERED and pushes the worker", () => {
    const job = offered();
    assert.equal(job.state, "OFFERED");
    assert.equal(job.currentOffer?.workerId, "worker");
  });

  test("the poster and excluded workers cannot be offered the job", () => {
    const funded = makeJob({ state: "FUNDED", excludedWorkerIds: ["worker"] });
    rejects(funded, { type: "OFFER_SENT", offerId: "o", workerId: "poster", expiresAt: iso(2) }, SYSTEM, "bad_request");
    rejects(funded, { type: "OFFER_SENT", offerId: "o", workerId: "worker", expiresAt: iso(2) }, SYSTEM, "bad_request");
  });

  test("decline goes back to FUNDED, excludes the worker, and asks for the next offer", () => {
    const { job, effects } = apply(offered(), { type: "OFFER_DECLINED", offerId: "o1" }, WORKER);
    assert.equal(job.state, "FUNDED");
    assert.equal(job.currentOffer, undefined);
    assert.deepEqual(job.excludedWorkerIds, ["worker"]);
    assert.ok(kinds(effects).includes("offer.next"));
  });

  test("another user cannot decline someone else's offer", () => {
    rejects(offered(), { type: "OFFER_DECLINED", offerId: "o1" }, OTHER, "forbidden");
  });

  test("expiry only applies when due and only to the current offer", () => {
    rejects(offered(), { type: "OFFER_EXPIRED", offerId: "o1" }, SYSTEM, "too_early", at(1));
    rejects(offered(), { type: "OFFER_EXPIRED", offerId: "old" }, SYSTEM, "offer_not_current", at(3));
    const { job } = apply(offered(), { type: "OFFER_EXPIRED", offerId: "o1" }, SYSTEM, at(3));
    assert.equal(job.state, "FUNDED");
  });

  test("no candidates schedules a rematch and tells the poster once", () => {
    const first = apply(makeJob({ state: "FUNDED", matchRounds: 1 }), { type: "CANDIDATES_EXHAUSTED" }, SYSTEM);
    assert.deepEqual(kinds(first.effects), ["schedule", "push:poster:no_match_yet"]);
    const later = apply(makeJob({ state: "FUNDED", matchRounds: 2 }), { type: "CANDIDATES_EXHAUSTED" }, SYSTEM);
    assert.deepEqual(kinds(later.effects), ["schedule"]);
  });

  test("no rematch is scheduled past the deadline or the round limit", () => {
    const nearDeadline = makeJob({ state: "FUNDED", matchRounds: 2, deadline: iso(5) });
    assert.deepEqual(apply(nearDeadline, { type: "CANDIDATES_EXHAUSTED" }, SYSTEM).effects, []);
    const manyRounds = makeJob({ state: "FUNDED", matchRounds: rules.maxMatchRounds });
    assert.deepEqual(apply(manyRounds, { type: "CANDIDATES_EXHAUSTED" }, SYSTEM).effects, []);
  });

  test("a stale rematch timer is rejected", () => {
    rejects(makeJob({ state: "FUNDED", matchRounds: 3 }), { type: "REMATCH", round: 2 }, SYSTEM, "invalid_transition");
    const { job } = apply(makeJob({ state: "FUNDED", matchRounds: 3 }), { type: "REMATCH", round: 3 }, SYSTEM);
    assert.equal(job.matchRounds, 4);
  });
});

describe("accepting", () => {
  test("the offered worker accepts before expiry", () => {
    const { job, effects } = apply(offered(), { type: "ACCEPT", offerId: "o1" }, WORKER);
    assert.equal(job.state, "ACCEPTED");
    assert.equal(job.workerId, "worker");
    assert.equal(job.currentOffer, undefined);
    assert.ok(kinds(effects).includes("push:poster:offer_accepted"));
  });

  test("accept after expiry fails even if the timer has not fired", () => {
    rejects(offered(), { type: "ACCEPT", offerId: "o1" }, WORKER, "offer_expired", at(2));
  });

  test("a second accept loses: the offer is no longer current", () => {
    rejects(accepted(), { type: "ACCEPT", offerId: "o1" }, WORKER, "offer_not_current");
  });

  test("a different user cannot accept", () => {
    rejects(offered(), { type: "ACCEPT", offerId: "o1" }, OTHER, "forbidden");
  });
});

describe("cancel, terms, withdraw", () => {
  test("poster can cancel before work starts and gets a refund", () => {
    for (const job of [makeJob({ state: "FUNDED" }), offered(), accepted()]) {
      const r = apply(job, { type: "CANCEL" }, POSTER);
      assert.equal(r.job.state, "REFUNDED");
      assert.ok(kinds(r.effects).includes("refund"));
    }
    const fromOffered = apply(offered(), { type: "CANCEL" }, POSTER);
    assert.ok(kinds(fromOffered.effects).includes("push:worker:job_canceled"));
    rejects(inProgress(), { type: "CANCEL" }, POSTER, "invalid_transition");
    rejects(makeJob({ state: "FUNDED" }), { type: "CANCEL" }, WORKER, "forbidden");
  });

  test("poster can extend the deadline or radius while unmatched", () => {
    const { job, effects } = apply(makeJob({ state: "FUNDED", matchRounds: 1 }), { type: "UPDATE_TERMS", deadline: iso(3000), radiusKm: 10 }, POSTER);
    assert.equal(job.deadline, iso(3000));
    assert.equal(job.radiusKm, 10);
    assert.equal(job.matchRounds, 2);
    assert.deepEqual(kinds(effects), ["match", "schedule"]);
    rejects(makeJob({ state: "FUNDED" }), { type: "UPDATE_TERMS", deadline: iso(-5) }, POSTER, "bad_request");
    rejects(makeJob({ state: "FUNDED", remote: true }), { type: "UPDATE_TERMS", radiusKm: 3 }, POSTER, "bad_request");
  });

  test("worker withdrawal re-opens the job and excludes them", () => {
    const { job, effects } = apply(inProgress(), { type: "WITHDRAW" }, WORKER);
    assert.equal(job.state, "FUNDED");
    assert.equal(job.workerId, undefined);
    assert.equal(job.challenge, undefined);
    assert.deepEqual(job.excludedWorkerIds, ["worker"]);
    assert.ok(kinds(effects).includes("match"));
  });
});

describe("doing the work", () => {
  test("in-person start requires a nearby check-in and issues the code", () => {
    rejects(accepted(), { type: "START", code: "X" }, WORKER, "location_required");
    rejects(accepted(), { type: "START", code: "X", at: { lat: 42.3, lng: -83.743 } }, WORKER, "too_far");
    const { job } = apply(accepted(), { type: "START", code: "ABC-DEF", at: { lat: 42.281, lng: -83.743 } }, WORKER);
    assert.equal(job.state, "IN_PROGRESS");
    assert.equal(job.challenge?.code, "ABC-DEF");
  });

  test("remote jobs start without a location", () => {
    const remoteAccepted = { ...accepted(), remote: true, location: undefined };
    assert.equal(apply(remoteAccepted, { type: "START", code: "X" }, WORKER).job.state, "IN_PROGRESS");
  });

  test("submit asks for grading; late submissions are refused", () => {
    const { job, effects } = apply(inProgress(), { type: "SUBMIT", proofId: "p1" }, WORKER);
    assert.equal(job.state, "SUBMITTED");
    assert.deepEqual(effects, [{ kind: "grade", proofId: "p1" }]);
    rejects(inProgress(), { type: "SUBMIT", proofId: "p1" }, WORKER, "deadline_passed", at(24 * 60 + 1));
  });
});

describe("grading and review", () => {
  test("a pass opens the review window", () => {
    const { job, effects } = apply(submitted(), { type: "GRADED", proofId: "p1", decision: "pass", summary: "ok" }, SYSTEM);
    assert.equal(job.state, "IN_REVIEW");
    assert.equal(job.review?.requiresPosterAction, false);
    assert.deepEqual(kinds(effects), ["push:poster:proof_ready", "push:worker:proof_passed", "schedule"]);
  });

  test("a grade for an older proof is ignored", () => {
    rejects(submitted(), { type: "GRADED", proofId: "p0", decision: "pass", summary: "" }, SYSTEM, "invalid_transition");
  });

  test("failures allow two retries, then the poster decides", () => {
    let job = submitted();
    for (let i = 1; i <= 2; i++) {
      job = apply(job, { type: "GRADED", proofId: job.latestProofId ?? "", decision: "fail", summary: "" }, SYSTEM).job;
      assert.equal(job.state, "IN_PROGRESS");
      assert.equal(job.failedAttempts, i);
      job = apply(job, { type: "SUBMIT", proofId: `p${i + 1}` }, WORKER).job;
    }
    job = apply(job, { type: "GRADED", proofId: "p3", decision: "fail", summary: "" }, SYSTEM).job;
    assert.equal(job.state, "IN_REVIEW");
    assert.equal(job.review?.requiresPosterAction, true);
  });

  test("a failure after the deadline goes to the poster instead of a retry", () => {
    const { job } = apply(submitted(), { type: "GRADED", proofId: "p1", decision: "fail", summary: "" }, SYSTEM, at(24 * 60 + 5));
    assert.equal(job.state, "IN_REVIEW");
    assert.equal(job.review?.requiresPosterAction, true);
  });

  test("unclear grades need the poster and never auto-release", () => {
    const review = apply(submitted(), { type: "GRADED", proofId: "p1", decision: "unclear", summary: "" }, SYSTEM).job;
    const { job, effects } = apply(review, { type: "REVIEW_WINDOW_EXPIRED" }, SYSTEM, at(48 * 60 + 2));
    assert.equal(job.state, "DISPUTED");
    assert.equal(job.dispute?.openedBy, "system");
    assert.ok(!kinds(effects).includes("payout"));
  });

  test("the review window auto-releases a passing job only when due", () => {
    const review = apply(submitted(), { type: "GRADED", proofId: "p1", decision: "pass", summary: "" }, SYSTEM).job;
    rejects(review, { type: "REVIEW_WINDOW_EXPIRED" }, SYSTEM, "too_early", at(60));
    const { job, effects } = apply(review, { type: "REVIEW_WINDOW_EXPIRED" }, SYSTEM, at(24 * 60 + 2));
    assert.equal(job.state, "RELEASED");
    assert.ok(kinds(effects).includes("payout"));
  });

  test("the poster approves or disputes a specific item", () => {
    const review = apply(submitted(), { type: "GRADED", proofId: "p1", decision: "pass", summary: "" }, SYSTEM).job;
    assert.equal(apply(review, { type: "APPROVE" }, POSTER).job.state, "RELEASED");
    rejects(review, { type: "APPROVE" }, WORKER, "forbidden");
    rejects(review, { type: "DISPUTE", itemId: "nope", reason: "bad" }, POSTER, "bad_request");
    const disputed = apply(review, { type: "DISPUTE", itemId: "c1", reason: "Logo is blurry" }, POSTER).job;
    assert.equal(disputed.state, "DISPUTED");
    rejects(disputed, { type: "RESOLVE", outcome: "refund" }, POSTER, "forbidden");
    const resolved = apply(disputed, { type: "RESOLVE", outcome: "refund" }, ADMIN);
    assert.equal(resolved.job.state, "REFUNDED");
    assert.ok(kinds(resolved.effects).includes("refund"));
  });
});

describe("deadlines and money confirmations", () => {
  test("unmatched and unfinished jobs are refunded at the deadline", () => {
    for (const job of [makeJob({ state: "FUNDED" }), offered(), accepted(), inProgress()]) {
      const r = apply(job, { type: "DEADLINE_PASSED" }, SYSTEM, at(24 * 60));
      assert.equal(r.job.state, "REFUNDED");
      assert.ok(kinds(r.effects).includes("refund"));
    }
    const missed = apply(accepted(), { type: "DEADLINE_PASSED" }, SYSTEM, at(24 * 60));
    assert.ok(missed.effects.some((e) => e.kind === "stats" && e.delta.jobsFailed === 1));
  });

  test("deadline does not touch submitted work or fire early", () => {
    rejects(submitted(), { type: "DEADLINE_PASSED" }, SYSTEM, "invalid_transition", at(24 * 60));
    rejects(accepted(), { type: "DEADLINE_PASSED" }, SYSTEM, "too_early", at(60));
  });

  test("payout and refund confirmations are recorded once", () => {
    const released = makeJob({ state: "RELEASED", workerId: "worker" });
    const { job } = apply(released, { type: "PAYOUT_CONFIRMED", transferId: "tr_1" }, SYSTEM);
    assert.equal(job.payment.transferId, "tr_1");
    rejects(job, { type: "PAYOUT_CONFIRMED", transferId: "tr_2" }, SYSTEM, "already_done");
    rejects(makeJob({ state: "IN_REVIEW" }), { type: "PAYOUT_CONFIRMED", transferId: "tr" }, SYSTEM, "invalid_transition");
  });
});

describe("ratings", () => {
  const closed = makeJob({ state: "RELEASED", workerId: "worker" });

  test("each side rates the other once", () => {
    const byPoster = apply(closed, { type: "RATE", stars: 5 }, POSTER);
    assert.deepEqual(byPoster.effects, [{ kind: "stats", userId: "worker", delta: { ratingSum: 5, ratingCount: 1 } }]);
    rejects(byPoster.job, { type: "RATE", stars: 4 }, POSTER, "already_done");
    const byWorker = apply(byPoster.job, { type: "RATE", stars: 4 }, WORKER);
    assert.equal(byWorker.job.ratings.byWorker?.stars, 4);
    rejects(closed, { type: "RATE", stars: 6 }, POSTER, "bad_request");
    rejects(closed, { type: "RATE", stars: 3 }, OTHER, "forbidden");
    rejects(makeJob({ state: "REFUNDED" }), { type: "RATE", stars: 3 }, POSTER, "invalid_transition");
  });
});

describe("allowedActions", () => {
  test("matches the state and the viewer", () => {
    assert.deepEqual(allowedActions(makeJob(), { userId: "poster" }, at(1)), ["edit_checklist", "fund", "delete"]);
    assert.deepEqual(allowedActions(offered(), { userId: "worker" }, at(1)), ["accept", "decline"]);
    assert.deepEqual(allowedActions(offered(), { userId: "worker" }, at(3)), []);
    assert.deepEqual(allowedActions(inProgress(), { userId: "worker" }, at(1)), ["submit_proof", "withdraw"]);
    assert.deepEqual(allowedActions(inProgress(), { userId: "other" }, at(1)), []);
    assert.deepEqual(allowedActions(makeJob({ state: "DISPUTED" }), { userId: "a", isAdmin: true }, at(1)), ["resolve"]);
  });
});
