import assert from "node:assert/strict";
import { test } from "node:test";
import type { Actor, Job } from "../domain/types.js";
import { testDeps } from "../testing/harness.js";
import { applyEvent, createJobRecord, getJobOrThrow } from "./jobs.js";
import { newUser } from "./users.js";

const SYSTEM: Actor = { kind: "system", source: "test" };

function draft(now: Date, deadlineMinutes: number): Job {
  return {
    jobId: "job1",
    posterId: "poster",
    title: "Mow a lawn",
    description: "",
    category: "HOME",
    photos: [],
    remote: true,
    radiusKm: 5,
    deadline: new Date(now.getTime() + deadlineMinutes * 60_000).toISOString(),
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

test("the deadline timer refunds an unmatched job and tells the poster", async () => {
  const deps = testDeps();
  await deps.store.createUser(newUser({ userId: "poster", displayName: "P" }, deps.now()));
  await createJobRecord(deps, draft(deps.now(), 60), { kind: "user", userId: "poster" });
  await applyEvent(deps, "job1", { type: "FUND_CONFIRMED", amountCents: 2200 }, SYSTEM);
  await deps.settle();
  assert.equal((await getJobOrThrow(deps, "job1")).state, "FUNDED");

  deps.clock.advance(3600);
  await deps.settle();
  assert.equal((await getJobOrThrow(deps, "job1")).state, "REFUNDED");
  assert.ok(deps.push.sent.some((p) => p.userId === "poster" && p.message.type === "unmatched_refund"));
});

test("an offer expiry timer is ignored after the worker already answered", async () => {
  const deps = testDeps();
  await createJobRecord(deps, draft(deps.now(), 600), { kind: "user", userId: "poster" });
  await applyEvent(deps, "job1", { type: "FUND_CONFIRMED", amountCents: 2200 }, SYSTEM);
  const expiresAt = new Date(deps.now().getTime() + 30_000).toISOString();
  await applyEvent(deps, "job1", { type: "OFFER_SENT", offerId: "o1", workerId: "w", expiresAt }, SYSTEM);
  await applyEvent(deps, "job1", { type: "ACCEPT", offerId: "o1" }, { kind: "user", userId: "w" });
  deps.clock.advance(60);
  await deps.settle();
  const job = await getJobOrThrow(deps, "job1");
  assert.equal(job.state, "ACCEPTED");
  assert.equal(job.workerId, "w");
});
