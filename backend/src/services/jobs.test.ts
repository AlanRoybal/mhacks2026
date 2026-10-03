import assert from "node:assert/strict";
import { test } from "node:test";
import { TransitionError } from "../domain/jobMachine.js";
import type { Actor, Job } from "../domain/types.js";
import { testDeps } from "../testing/harness.js";
import { runEffects } from "./effects.js";
import { applyEvent, createJobRecord } from "./jobs.js";
import { getUserOrThrow, newUser } from "./users.js";

const SYSTEM: Actor = { kind: "system", source: "test" };

function draft(now: Date): Job {
  return {
    jobId: "job1",
    posterId: "poster",
    title: "Sketch a logo",
    description: "",
    category: "design",
    photos: [],
    remote: true,
    radiusKm: 5,
    deadline: new Date(now.getTime() + 86_400_000).toISOString(),
    estMinutes: 15,
    bountyCents: 1500,
    feeCents: 150,
    totalCents: 1650,
    rail: "fake",
    state: "DRAFT",
    version: 1,
    checklist: [],
    excludedWorkerIds: [],
    failedAttempts: 0,
    payment: {},
    ratings: {},
    matchRounds: 0,
    createdAt: now.toISOString(),
    updatedAt: now.toISOString(),
  };
}

test("applyEvent commits the job and a ledger row with the same seq", async () => {
  const deps = testDeps();
  await createJobRecord(deps, draft(deps.now()), { kind: "user", userId: "poster" });
  const job = await applyEvent(deps, "job1", { type: "FUND_CONFIRMED", amountCents: 1650 }, SYSTEM);
  assert.equal(job.state, "FUNDED");
  assert.equal(job.version, 2);
  const ledger = await deps.store.listLedger("job1");
  assert.deepEqual(
    ledger.map((e) => [e.seq, e.type, e.to]),
    [
      [1, "CREATED", "DRAFT"],
      [2, "FUND_CONFIRMED", "FUNDED"],
    ],
  );
  await deps.inlineEffects.drain();
});

test("two concurrent responses to one offer: exactly one wins", async () => {
  const deps = testDeps();
  const now = deps.now();
  await createJobRecord(deps, draft(now), { kind: "user", userId: "poster" });
  await applyEvent(deps, "job1", { type: "FUND_CONFIRMED", amountCents: 1650 }, SYSTEM);
  const expiresAt = new Date(now.getTime() + 30_000).toISOString();
  await applyEvent(deps, "job1", { type: "OFFER_SENT", offerId: "o1", workerId: "worker", expiresAt }, SYSTEM);
  deps.clock.advance(31);

  const results = await Promise.allSettled([
    applyEvent(deps, "job1", { type: "OFFER_DECLINED", offerId: "o1" }, { kind: "user", userId: "worker" }),
    applyEvent(deps, "job1", { type: "OFFER_EXPIRED", offerId: "o1" }, SYSTEM),
  ]);
  const won = results.filter((r) => r.status === "fulfilled");
  const lost = results.filter((r): r is PromiseRejectedResult => r.status === "rejected");
  assert.equal(won.length, 1);
  assert.equal(lost.length, 1);
  assert.ok(lost[0]?.reason instanceof TransitionError);
  assert.equal(lost[0]?.reason.code, "offer_not_current");
  await deps.inlineEffects.drain();
});

test("stats effects update the user after the commit", async () => {
  const deps = testDeps();
  const now = deps.now();
  await deps.store.createUser(newUser({ userId: "worker", displayName: "W" }, now));
  await createJobRecord(deps, draft(now), { kind: "user", userId: "poster" });
  await applyEvent(deps, "job1", { type: "FUND_CONFIRMED", amountCents: 1650 }, SYSTEM);
  const expiresAt = new Date(now.getTime() + 30_000).toISOString();
  await applyEvent(deps, "job1", { type: "OFFER_SENT", offerId: "o1", workerId: "worker", expiresAt }, SYSTEM);
  await applyEvent(deps, "job1", { type: "ACCEPT", offerId: "o1" }, { kind: "user", userId: "worker" });
  await deps.inlineEffects.drain();
  const worker = await getUserOrThrow(deps, "worker");
  assert.equal(worker.stats.offersReceived, 1);
  assert.equal(worker.stats.offersAccepted, 1);
});

test("re-running a ledger row does not double-count stats or re-send pushes", async () => {
  const deps = testDeps();
  const now = deps.now();
  await deps.store.createUser(newUser({ userId: "worker", displayName: "W" }, now));
  await createJobRecord(deps, draft(now), { kind: "user", userId: "poster" });
  await applyEvent(deps, "job1", { type: "FUND_CONFIRMED", amountCents: 1650 }, SYSTEM);
  const expiresAt = new Date(now.getTime() + 30_000).toISOString();
  await applyEvent(deps, "job1", { type: "OFFER_SENT", offerId: "o1", workerId: "worker", expiresAt }, SYSTEM);
  await deps.inlineEffects.drain();
  const row = (await deps.store.listLedger("job1")).at(-1);
  assert.ok(row);
  await runEffects(deps, row);
  const worker = await getUserOrThrow(deps, "worker");
  assert.equal(worker.stats.offersReceived, 1);
  assert.equal(deps.push.sent.filter((p) => p.message.type === "offer").length, 1);
});
