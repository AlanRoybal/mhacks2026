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
const DAY = 24 * 60;

const POSTER: Actor = { kind: "user", userId: "poster" };
const WORKER: Actor = { kind: "user", userId: "worker" };
const OTHER: Actor = { kind: "user", userId: "other" };
const SYSTEM: Actor = { kind: "system", source: "test" };
const ADMIN: Actor = { kind: "admin", userId: "admin" };

const SITE = { lat: 42.2808, lng: -83.743 };
const FUND: JobEvent = { type: "FUND_CONFIRMED", amountCents: 1650, paymentIntentId: "pi_1", chargeId: "ch_1" };

function makeJob(overrides: Partial<Job> = {}): Job {
  return {
    jobId: "job1",
    posterId: "poster",
    title: "Sketch a logo",
    description: "Coffee shop logo on paper",
    category: "DESIGN",
    photos: [],
    remote: false,
    location: SITE,
    radiusKm: 5,
    deadline: iso(DAY),
    estMinutes: 15,
    bountyCents: 1500,
    feeCents: 150,
    totalCents: 1650,
    currency: "USD",
    rail: "fake",
    state: "DRAFT",
    version: 1,
    checklist: [{ id: "c1", text: "Logo is visible", evidenceType: "PHOTO", photoCount: 1, required: true }],
    flags: [],
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

const kinds = (effects: Effect[]) => effects.map((e) => (e.kind === "push" ? `push:${e.to}:${e.template}` : e.kind === "schedule" ? `schedule:${e.timer}` : e.kind));

const funded = () => apply(makeJob(), FUND, SYSTEM).job;
const offered = () => apply(funded(), { type: "OFFER_SENT", offerId: "o1", workerId: "worker", expiresAt: iso(2) }, SYSTEM).job;
const accepted = () => apply(offered(), { type: "ACCEPT", offerId: "o1" }, WORKER).job;
const inProgress = () => apply(accepted(), { type: "START", code: "ABC-DEF", at: SITE }, WORKER).job;
const submitted = () => apply(inProgress(), { type: "SUBMIT", proofId: "p1" }, WORKER).job;
const graded = (decision: "pass" | "fail" | "unclear") => apply(submitted(), { type: "GRADED", proofId: "p1", decision, summary: "" }, SYSTEM).job;

describe("funding", () => {
  test("starts matching and the deadline timer", () => {
    const { job, effects } = apply(makeJob(), FUND, SYSTEM);
    assert.equal(job.state, "FUNDED");
    assert.equal(job.matchRounds, 1);
    assert.equal(job.payment.chargeId, "ch_1");
    assert.deepEqual(kinds(effects), ["match", "schedule:deadline"]);
  });

  test("only the platform can confirm, only once, and only for the right amount and checkout", () => {
    rejects(makeJob(), FUND, POSTER, "forbidden");
    rejects(funded(), FUND, SYSTEM, "invalid_transition");
    rejects(makeJob(), { ...FUND, amountCents: 1500 }, SYSTEM, "bad_request");
    rejects(makeJob({ payment: { paymentIntentId: "pi_other" } }), FUND, SYSTEM, "bad_request");
  });
});

describe("offers", () => {
  test("an offer moves the job to OFFERED", () => {
    const job = offered();
    assert.equal(job.state, "OFFERED");
    assert.equal(job.currentOffer?.workerId, "worker");
  });

  test("the poster, excluded workers, and offers without enough time left are refused", () => {
    const send = (workerId: string) => ({ type: "OFFER_SENT" as const, offerId: "o", workerId, expiresAt: iso(2) });
    rejects(funded(), send("poster"), SYSTEM, "bad_request");
    rejects({ ...funded(), excludedWorkerIds: ["worker"] }, send("worker"), SYSTEM, "bad_request");
    rejects(funded(), send("worker"), SYSTEM, "not_enough_time", at(DAY - 10));
  });

  test("decline goes back to FUNDED, excludes the worker, and asks for the next offer", () => {
    const { job, effects } = apply(offered(), { type: "OFFER_DECLINED", offerId: "o1" }, WORKER);
    assert.equal(job.state, "FUNDED");
    assert.equal(job.currentOffer, undefined);
    assert.deepEqual(job.excludedWorkerIds, ["worker"]);
    assert.ok(kinds(effects).includes("offer.next"));
    rejects(offered(), { type: "OFFER_DECLINED", offerId: "o1" }, OTHER, "forbidden");
  });

  test("expiry applies only when due and only to the current offer", () => {
    rejects(offered(), { type: "OFFER_EXPIRED", offerId: "o1" }, SYSTEM, "too_early", at(1.99));
    rejects(offered(), { type: "OFFER_EXPIRED", offerId: "old" }, SYSTEM, "offer_not_current", at(3));
    assert.equal(apply(offered(), { type: "OFFER_EXPIRED", offerId: "o1" }, SYSTEM, at(2)).job.state, "FUNDED");
  });

  test("accept and expiry never overlap", () => {
    rejects(offered(), { type: "ACCEPT", offerId: "o1" }, WORKER, "offer_expired", at(2));
    rejects(offered(), { type: "OFFER_EXPIRED", offerId: "o1" }, SYSTEM, "too_early", at(1.999));
  });

  test("no candidates schedules a rematch, tells the poster once, and ignores repeats", () => {
    const first = apply(funded(), { type: "CANDIDATES_EXHAUSTED", round: 1 }, SYSTEM);
    assert.deepEqual(kinds(first.effects), ["schedule:rematch", "push:poster:no_match_yet"]);
    rejects(first.job, { type: "CANDIDATES_EXHAUSTED", round: 1 }, SYSTEM, "invalid_transition");
    rejects(funded(), { type: "CANDIDATES_EXHAUSTED", round: 0 }, SYSTEM, "invalid_transition");
    const later = apply({ ...funded(), matchRounds: 2 }, { type: "CANDIDATES_EXHAUSTED", round: 2 }, SYSTEM);
    assert.deepEqual(kinds(later.effects), ["schedule:rematch"]);
  });

  test("rematches back off but never stop before the deadline", () => {
    assert.deepEqual(apply({ ...funded(), deadline: iso(5) }, { type: "CANDIDATES_EXHAUSTED", round: 1 }, SYSTEM).effects.filter((e) => e.kind === "schedule"), []);
    const delayAfter = (round: number) => {
      const effect = apply({ ...funded(), matchRounds: round }, { type: "CANDIDATES_EXHAUSTED", round }, SYSTEM, at(0)).effects.find((e) => e.kind === "schedule");
      return effect?.kind === "schedule" ? (Date.parse(effect.at) - at(0).getTime()) / 1000 : null;
    };
    assert.equal(delayAfter(1), rules.rematchDelaySec);
    assert.equal(delayAfter(2), rules.rematchDelaySec * 2);
    assert.equal(delayAfter(50), rules.maxRematchDelaySec);
  });

  test("a stale rematch timer is rejected", () => {
    rejects({ ...funded(), matchRounds: 3 }, { type: "REMATCH", round: 2 }, SYSTEM, "invalid_transition");
    assert.equal(apply({ ...funded(), matchRounds: 3 }, { type: "REMATCH", round: 3 }, SYSTEM).job.matchRounds, 4);
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

  test("a second tap by the winner says already accepted; anyone else sees the offer is gone", () => {
    rejects(accepted(), { type: "ACCEPT", offerId: "o1" }, WORKER, "already_done");
    rejects(accepted(), { type: "ACCEPT", offerId: "o1" }, OTHER, "offer_not_current");
    rejects(offered(), { type: "ACCEPT", offerId: "o1" }, OTHER, "forbidden");
  });

  test("cannot accept without enough time to do the work", () => {
    const tight = apply({ ...funded(), deadline: iso(20) }, { type: "OFFER_SENT", offerId: "o1", workerId: "worker", expiresAt: iso(7) }, SYSTEM).job;
    rejects(tight, { type: "ACCEPT", offerId: "o1" }, WORKER, "not_enough_time", at(6));
  });
});

describe("cancel, terms, withdraw", () => {
  test("poster can cancel only before a worker accepts (US-18)", () => {
    for (const job of [funded(), offered()]) {
      const r = apply(job, { type: "CANCEL" }, POSTER);
      assert.equal(r.job.state, "REFUNDED");
      assert.ok(kinds(r.effects).includes("refund"));
    }
    assert.ok(kinds(apply(offered(), { type: "CANCEL" }, POSTER).effects).includes("push:worker:job_canceled"));
    rejects(accepted(), { type: "CANCEL" }, POSTER, "invalid_transition");
    rejects(funded(), { type: "CANCEL" }, WORKER, "forbidden");
  });

  test("poster can extend the deadline or radius while unmatched; bad values are refused", () => {
    const { job, effects } = apply(funded(), { type: "UPDATE_TERMS", deadline: iso(3000), radiusKm: 10 }, POSTER);
    assert.equal(job.deadline, iso(3000));
    assert.equal(job.radiusKm, 10);
    assert.equal(job.matchRounds, 2);
    assert.deepEqual(kinds(effects), ["match", "schedule:deadline"]);
    rejects(funded(), { type: "UPDATE_TERMS", deadline: iso(-5) }, POSTER, "bad_request");
    rejects(funded(), { type: "UPDATE_TERMS", deadline: "next tuesday" }, POSTER, "bad_request");
    rejects(funded(), { type: "UPDATE_TERMS", radiusKm: -5 }, POSTER, "bad_request");
    rejects({ ...funded(), remote: true }, { type: "UPDATE_TERMS", radiusKm: 3 }, POSTER, "bad_request");
    rejects(funded(), { type: "UPDATE_TERMS", radiusKm: 3 }, WORKER, "forbidden");
  });

  test("an old deadline timer is stale after the deadline is extended", () => {
    const extended = apply(funded(), { type: "UPDATE_TERMS", deadline: iso(3 * DAY) }, POSTER).job;
    rejects(extended, { type: "DEADLINE_PASSED" }, SYSTEM, "too_early", at(DAY));
  });

  test("worker withdrawal re-opens the job and excludes them", () => {
    for (const job of [accepted(), inProgress()]) {
      const { job: next, effects } = apply(job, { type: "WITHDRAW" }, WORKER);
      assert.equal(next.state, "FUNDED");
      assert.equal(next.workerId, undefined);
      assert.equal(next.challenge, undefined);
      assert.deepEqual(next.excludedWorkerIds, ["worker"]);
      assert.ok(kinds(effects).includes("match"));
    }
    rejects(inProgress(), { type: "WITHDRAW" }, POSTER, "forbidden");
  });
});

describe("doing the work", () => {
  test("in-person start requires a nearby check-in and a code", () => {
    rejects(accepted(), { type: "START", code: "X" }, WORKER, "location_required");
    rejects(accepted(), { type: "START", code: "X", at: { lat: Number.NaN, lng: Number.NaN } }, WORKER, "location_required");
    rejects(accepted(), { type: "START", code: "X", at: { lat: 42.3, lng: -83.743 } }, WORKER, "too_far");
    rejects(accepted(), { type: "START", code: " ", at: SITE }, WORKER, "bad_request");
    rejects(accepted(), { type: "START", code: "X", at: SITE }, OTHER, "forbidden");
    const { job } = apply(accepted(), { type: "START", code: "ABC-DEF", at: { lat: 42.281, lng: -83.743 } }, WORKER);
    assert.equal(job.state, "IN_PROGRESS");
    assert.equal(job.challenge?.code, "ABC-DEF");
  });

  test("remote jobs start without a location", () => {
    assert.equal(apply({ ...accepted(), remote: true, location: undefined }, { type: "START", code: "X" }, WORKER).job.state, "IN_PROGRESS");
  });

  test("submit asks for grading with a timeout; late, repeated or foreign submissions are refused", () => {
    const { job, effects } = apply(inProgress(), { type: "SUBMIT", proofId: "p1" }, WORKER);
    assert.equal(job.state, "SUBMITTED");
    assert.deepEqual(kinds(effects), ["grade", "schedule:grade_timeout"]);
    rejects(inProgress(), { type: "SUBMIT", proofId: "p1" }, WORKER, "deadline_passed", at(DAY));
    rejects(inProgress(), { type: "SUBMIT", proofId: "p1" }, OTHER, "forbidden");
    const retry = apply(submitted(), { type: "GRADED", proofId: "p1", decision: "fail", summary: "" }, SYSTEM).job;
    rejects(retry, { type: "SUBMIT", proofId: "p1" }, WORKER, "already_done");
  });
});

describe("grading and review", () => {
  test("a pass opens the review window", () => {
    const { job, effects } = apply(submitted(), { type: "GRADED", proofId: "p1", decision: "pass", summary: "ok" }, SYSTEM);
    assert.equal(job.state, "IN_REVIEW");
    assert.equal(job.review?.requiresPosterAction, false);
    assert.deepEqual(kinds(effects), ["push:poster:proof_ready", "schedule:review_window", "push:worker:proof_passed"]);
  });

  test("grades for an older proof, or from users, are ignored", () => {
    rejects(submitted(), { type: "GRADED", proofId: "p0", decision: "pass", summary: "" }, SYSTEM, "invalid_transition");
    rejects(submitted(), { type: "GRADED", proofId: "p1", decision: "pass", summary: "" }, WORKER, "forbidden");
  });

  test("failures allow two retries, re-arm the deadline, then the poster decides", () => {
    let job = submitted();
    for (let i = 1; i <= 2; i++) {
      const r = apply(job, { type: "GRADED", proofId: job.latestProofId ?? "", decision: "fail", summary: "" }, SYSTEM);
      job = r.job;
      assert.equal(job.state, "IN_PROGRESS");
      assert.equal(job.failedAttempts, i);
      assert.ok(kinds(r.effects).includes("schedule:deadline"));
      job = apply(job, { type: "SUBMIT", proofId: `p${i + 1}` }, WORKER).job;
    }
    job = apply(job, { type: "GRADED", proofId: "p3", decision: "fail", summary: "" }, SYSTEM).job;
    assert.equal(job.state, "IN_REVIEW");
    assert.equal(job.review?.requiresPosterAction, true);
  });

  test("an unclear grade does not count as a failed attempt", () => {
    assert.equal(graded("unclear").failedAttempts, 0);
  });

  test("a failure after the deadline goes to the poster instead of a retry", () => {
    const { job } = apply(submitted(), { type: "GRADED", proofId: "p1", decision: "fail", summary: "" }, SYSTEM, at(DAY + 5));
    assert.equal(job.state, "IN_REVIEW");
    assert.equal(job.review?.requiresPosterAction, true);
  });

  test("grading that never returns times out to the poster", () => {
    rejects(submitted(), { type: "GRADE_TIMEOUT", proofId: "p1" }, SYSTEM, "too_early", at(5));
    rejects(submitted(), { type: "GRADE_TIMEOUT", proofId: "p0" }, SYSTEM, "invalid_transition", at(60));
    const { job } = apply(submitted(), { type: "GRADE_TIMEOUT", proofId: "p1" }, SYSTEM, at(1 + rules.gradeTimeoutSec / 60));
    assert.equal(job.state, "IN_REVIEW");
    assert.equal(job.review?.decision, "unclear");
    assert.equal(job.review?.requiresPosterAction, true);
    rejects(graded("pass"), { type: "GRADE_TIMEOUT", proofId: "p1" }, SYSTEM, "invalid_transition", at(60));
  });

  test("the review window auto-releases a passing job only when due", () => {
    rejects(graded("pass"), { type: "REVIEW_WINDOW_EXPIRED" }, SYSTEM, "too_early", at(60));
    const { job, effects } = apply(graded("pass"), { type: "REVIEW_WINDOW_EXPIRED" }, SYSTEM, at(DAY + 2));
    assert.equal(job.state, "RELEASED");
    assert.ok(kinds(effects).includes("payout"));
    const approved = apply(graded("pass"), { type: "APPROVE" }, POSTER).job;
    rejects(approved, { type: "REVIEW_WINDOW_EXPIRED" }, SYSTEM, "invalid_transition", at(DAY + 2));
  });

  test("unclear grades need the poster; silence escalates to a dispute with its own timeout", () => {
    const { job, effects } = apply(graded("unclear"), { type: "REVIEW_WINDOW_EXPIRED" }, SYSTEM, at(2 * DAY + 2));
    assert.equal(job.state, "DISPUTED");
    assert.equal(job.dispute?.openedBy, "system");
    assert.ok(!kinds(effects).includes("payout"));
    assert.ok(kinds(effects).includes("schedule:dispute_timeout"));
  });

  test("the poster approves, rejects failed work, or disputes a specific item while the window is open", () => {
    assert.equal(apply(graded("pass"), { type: "APPROVE" }, POSTER).job.state, "RELEASED");
    rejects(graded("pass"), { type: "APPROVE" }, WORKER, "forbidden");
    rejects(graded("pass"), { type: "REJECT" }, POSTER, "invalid_transition");
    rejects(graded("pass"), { type: "DISPUTE", itemId: "nope", reason: "bad" }, POSTER, "bad_request");
    rejects(graded("pass"), { type: "DISPUTE", itemId: "c1", reason: "blurry" }, POSTER, "window_closed", at(DAY + 2));
    const disputed = apply(graded("pass"), { type: "DISPUTE", itemId: "c1", reason: "Logo is blurry" }, POSTER);
    assert.equal(disputed.job.state, "DISPUTED");
    assert.ok(kinds(disputed.effects).includes("schedule:dispute_timeout"));

    let failed = submitted();
    for (let i = 1; i <= 3; i++) {
      failed = apply(failed, { type: "GRADED", proofId: failed.latestProofId ?? "", decision: "fail", summary: "" }, SYSTEM).job;
      if (failed.state === "IN_PROGRESS") failed = apply(failed, { type: "SUBMIT", proofId: `p${i + 1}` }, WORKER).job;
    }
    const rejected = apply(failed, { type: "REJECT" }, POSTER);
    assert.equal(rejected.job.state, "REFUNDED");
    assert.ok(kinds(rejected.effects).includes("refund"));
  });

  test("disputes end by admin, by the poster conceding, or by timeout", () => {
    const disputed = apply(graded("pass"), { type: "DISPUTE", itemId: "c1", reason: "Logo is blurry" }, POSTER).job;
    rejects(disputed, { type: "RESOLVE", outcome: "refund" }, POSTER, "forbidden");
    rejects(disputed, { type: "RESOLVE", outcome: "refund" }, { kind: "admin", userId: "poster" }, "forbidden");
    assert.equal(apply(disputed, { type: "RESOLVE", outcome: "refund" }, ADMIN).job.state, "REFUNDED");
    assert.equal(apply(disputed, { type: "RESOLVE", outcome: "release" }, ADMIN).job.state, "RELEASED");
    assert.equal(apply(disputed, { type: "APPROVE" }, POSTER).job.state, "RELEASED");
    rejects(disputed, { type: "DISPUTE_TIMEOUT" }, SYSTEM, "too_early", at(60));
    const timedOut = apply(disputed, { type: "DISPUTE_TIMEOUT" }, SYSTEM, at(1 + rules.disputeWindowSec / 60));
    assert.equal(timedOut.job.state, "RELEASED", "a passing grade stands");
    assert.equal(timedOut.job.resolution?.by, "system");
  });
});

describe("deadlines and money confirmations", () => {
  test("unmatched and unfinished jobs are refunded at the deadline", () => {
    for (const job of [funded(), offered(), accepted(), inProgress()]) {
      const r = apply(job, { type: "DEADLINE_PASSED" }, SYSTEM, at(DAY));
      assert.equal(r.job.state, "REFUNDED");
      assert.ok(kinds(r.effects).includes("refund"));
    }
    assert.ok(kinds(apply(offered(), { type: "DEADLINE_PASSED" }, SYSTEM, at(DAY)).effects).includes("push:worker:offer_closed"));
    const missed = apply(accepted(), { type: "DEADLINE_PASSED" }, SYSTEM, at(DAY));
    assert.ok(missed.effects.some((e) => e.kind === "stats" && e.delta.jobsFailed === 1));
  });

  test("deadline does not touch submitted work and never fires early", () => {
    rejects(submitted(), { type: "DEADLINE_PASSED" }, SYSTEM, "invalid_transition", at(DAY));
    rejects(accepted(), { type: "DEADLINE_PASSED" }, SYSTEM, "too_early", at(DAY - 0.01));
  });

  test("payout and refund confirmations are recorded once", () => {
    const released = makeJob({ state: "RELEASED", workerId: "worker" });
    const { job } = apply(released, { type: "PAYOUT_CONFIRMED", transferId: "tr_1" }, SYSTEM);
    assert.equal(job.payment.transferId, "tr_1");
    rejects(job, { type: "PAYOUT_CONFIRMED", transferId: "tr_2" }, SYSTEM, "already_done");
    rejects(makeJob({ state: "IN_REVIEW" }), { type: "PAYOUT_CONFIRMED", transferId: "tr" }, SYSTEM, "invalid_transition");
    const refunded = apply(makeJob({ state: "REFUNDED" }), { type: "REFUND_CONFIRMED", refundId: "re_1" }, SYSTEM);
    assert.deepEqual(kinds(refunded.effects), ["push:poster:refunded"]);
    rejects(refunded.job, { type: "REFUND_CONFIRMED", refundId: "re_2" }, SYSTEM, "already_done");
  });
});

describe("ratings", () => {
  const closed = makeJob({ state: "RELEASED", workerId: "worker" });

  test("each side rates the other once", () => {
    const byPoster = apply(closed, { type: "RATE", stars: 5 }, POSTER);
    assert.deepEqual(byPoster.effects, [{ kind: "stats", userId: "worker", delta: { ratingSum: 5, ratingCount: 1 } }]);
    rejects(byPoster.job, { type: "RATE", stars: 4 }, POSTER, "already_done");
    assert.equal(apply(byPoster.job, { type: "RATE", stars: 4 }, WORKER).job.ratings.byWorker?.stars, 4);
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
    assert.deepEqual(allowedActions(accepted(), { userId: "poster" }, at(1)), []);
    assert.deepEqual(allowedActions(inProgress(), { userId: "worker" }, at(1)), ["submit_proof", "withdraw"]);
    assert.deepEqual(allowedActions(graded("pass"), { userId: "poster" }, at(1)), ["approve", "dispute"]);
    assert.deepEqual(allowedActions(makeJob({ state: "DISPUTED" }), { userId: "a", isAdmin: true }, at(1)), ["resolve"]);
    assert.deepEqual(allowedActions(makeJob({ state: "DISPUTED" }), { userId: "poster", isAdmin: true }, at(1)), ["approve"]);
  });
});

// Random walks through the machine: whatever happens, money moves at most once and OFFERED <=> currentOffer.
describe("invariants under random event sequences", () => {
  function seeded(seed: number) {
    let s = seed;
    return () => {
      s = (s * 1103515245 + 12345) % 2 ** 31;
      return s / 2 ** 31;
    };
  }

  test("10,000 random runs", () => {
    const actors = [POSTER, WORKER, OTHER, SYSTEM, ADMIN];
    for (let run = 0; run < 10_000; run++) {
      const rand = seeded(run + 1);
      const pick = <T>(xs: T[]) => xs[Math.floor(rand() * xs.length)] as T;
      let job = makeJob();
      let minute = 0;
      let moneyMoves = 0;
      for (let step = 0; step < 40; step++) {
        minute += Math.floor(rand() * 600);
        const events: JobEvent[] = [
          FUND,
          { type: "OFFER_SENT", offerId: `o${step}`, workerId: pick(["worker", "other"]), expiresAt: iso(minute + 1) },
          { type: "OFFER_DECLINED", offerId: job.currentOffer?.offerId ?? "x" },
          { type: "OFFER_EXPIRED", offerId: job.currentOffer?.offerId ?? "x" },
          { type: "CANDIDATES_EXHAUSTED", round: job.matchRounds },
          { type: "REMATCH", round: job.matchRounds },
          { type: "ACCEPT", offerId: job.currentOffer?.offerId ?? "x" },
          { type: "CANCEL" },
          { type: "START", code: "ABC-DEF", at: SITE },
          { type: "WITHDRAW" },
          { type: "SUBMIT", proofId: `p${step}` },
          { type: "GRADED", proofId: job.latestProofId ?? "x", decision: pick(["pass", "fail", "unclear"] as const), summary: "" },
          { type: "GRADE_TIMEOUT", proofId: job.latestProofId ?? "x" },
          { type: "APPROVE" },
          { type: "REJECT" },
          { type: "REVIEW_WINDOW_EXPIRED" },
          { type: "DISPUTE", itemId: "c1", reason: "bad" },
          { type: "RESOLVE", outcome: pick(["release", "refund"] as const) },
          { type: "DISPUTE_TIMEOUT" },
          { type: "DEADLINE_PASSED" },
        ];
        try {
          const r = apply(job, pick(events), pick(actors), at(minute));
          moneyMoves += r.effects.filter((e) => e.kind === "payout" || e.kind === "refund").length;
          job = r.job;
        } catch (e) {
          if (!(e instanceof TransitionError)) throw e;
        }
        assert.equal(job.state === "OFFERED", Boolean(job.currentOffer), `run ${run}: OFFERED <=> currentOffer`);
        assert.ok(moneyMoves <= 1, `run ${run}: money moved ${moneyMoves} times`);
      }
    }
  });
});
