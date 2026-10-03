import assert from "node:assert/strict";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import type { LedgerEvent } from "../domain/events.js";
import type { Job } from "../domain/types.js";
import { MemoryStore } from "./memoryStore.js";
import { VersionConflictError } from "./store.js";

const job = { jobId: "j1", posterId: "p", version: 1, createdAt: "2026-01-01", updatedAt: "2026-01-01" } as Job;
const ledger = (seq: number): LedgerEvent => ({
  jobId: "j1",
  seq,
  type: "CREATED",
  from: null,
  to: "DRAFT",
  actor: { kind: "system", source: "test" },
  event: null,
  effects: [],
  at: "2026-01-01",
  inline: true,
});

test("commitTransition rejects a stale version", async () => {
  const store = new MemoryStore();
  await store.createJob(job, ledger(1));
  await store.commitTransition(1, { ...job, version: 2 }, ledger(2));
  await assert.rejects(store.commitTransition(1, { ...job, version: 2 }, ledger(2)), VersionConflictError);
  assert.equal((await store.listLedger("j1")).length, 2);
});

test("undefined attributes are dropped, like DynamoDB", async () => {
  const store = new MemoryStore();
  await store.createJob({ ...job, workerId: undefined }, ledger(1));
  assert.ok(!("workerId" in ((await store.getJob("j1")) ?? {})));
});

test("kvPut ifAbsent only lets one caller win", async () => {
  const store = new MemoryStore();
  const results = await Promise.all([store.kvPut("k", 1, { ifAbsent: true }), store.kvPut("k", 2, { ifAbsent: true })]);
  assert.deepEqual(results.sort(), [false, true]);
  assert.equal(await store.kvGet("k"), 1);
});

test("snapshots survive a restart", async () => {
  const file = join(mkdtempSync(join(tmpdir(), "bounty-")), "store.json");
  await new MemoryStore(file).createJob(job, ledger(1));
  assert.equal((await new MemoryStore(file).getJob("j1"))?.posterId, "p");
});
