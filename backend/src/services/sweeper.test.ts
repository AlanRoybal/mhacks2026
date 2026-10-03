import assert from "node:assert/strict";
import { test } from "node:test";
import type { Job } from "../domain/types.js";
import { testDeps } from "../testing/harness.js";
import { applyEvent, createJobRecord, getJobOrThrow } from "./jobs.js";
import { sweep } from "./sweeper.js";
import { newUser } from "./users.js";

const SYSTEM = { kind: "system" as const, source: "test" };

function draft(now: Date): Job {
  return {
    jobId: "job1",
    posterId: "poster",
    title: "Mow a lawn",
    description: "",
    category: "YARD_WORK",
    photos: [],
    remote: true,
    radiusKm: 5,
    deadline: new Date(now.getTime() + 3600_000).toISOString(),
    estMinutes: 30,
    bountyCents: 2000,
    feeCents: 200,
    totalCents: 2200,
    currency: "USD",
    rail: "fake",
    state: "DRAFT",
    version: 1,
    checklist: [],
    flags: [],
    excludedWorkerIds: [],
    failedAttempts: 0,
    payment: {},
    ratings: {},
    matchRounds: 0,
    createdAt: now.toISOString(),
    updatedAt: now.toISOString(),
  };
}

test("a lost deadline timer is caught by the sweep, and the refund goes out", async () => {
  const deps = testDeps();
  await createJobRecord(deps, draft(deps.now()), { kind: "user", userId: "poster" });
  await applyEvent(deps, "job1", { type: "FUND_CONFIRMED", amountCents: 2200 }, SYSTEM);
  await deps.inlineEffects.drain();
  deps.scheduler.pending.clear(); // simulate the scheduler losing every timer

  deps.clock.advance(3601);
  const result = await sweep(deps);
  await deps.inlineEffects.drain();
  assert.ok(result.actions >= 1);
  const job = await getJobOrThrow(deps, "job1");
  assert.equal(job.state, "REFUNDED");
  assert.equal(job.payment.refundId, "fake_re_job1");
});

test("a released job whose payout effect was lost is paid by the sweep", async () => {
  const deps = testDeps();
  const now = deps.now();
  await deps.store.createJob({ ...draft(now), state: "RELEASED", workerId: "w" }, {
    jobId: "job1", seq: 1, type: "CREATED", from: null, to: "RELEASED", actor: SYSTEM, event: null, effects: [], at: now.toISOString(), inline: true,
  });
  await deps.store.createUser(newUser({ userId: "w", displayName: "W" }, now));
  deps.clock.advance(300);
  await sweep(deps);
  await deps.inlineEffects.drain();
  assert.equal((await getJobOrThrow(deps, "job1")).payment.transferId, "fake_tr_job1");
  assert.equal((await sweep(deps)).checked, 0, "nothing left to do");
});
