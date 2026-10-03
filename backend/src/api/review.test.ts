import assert from "node:assert/strict";
import { test } from "node:test";
import { FakeAi } from "../ai/fake.js";
import { getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn, type Json } from "../testing/api.js";
import { testDeps, type TestDeps } from "../testing/harness.js";

// A remote LINK-only job that has passed AI review and is waiting on the poster.
async function inReview(deps: TestDeps) {
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const worker = await api.readyWorker("tutor", { skill: "Calculus tutoring", lat: 42.28, lng: -83.74 });
  const { body: draft } = await api.call("POST", "/jobs", poster.token, {
    title: "Calc II tutoring, 1 hour",
    description: "Series convergence tests before Friday's exam",
    category: "TUTORING",
    location: null,
    deadline: isoIn(deps, 8),
    payAmount: 25,
  });
  await api.call("PUT", `/jobs/${draft.id}/checklist`, poster.token, [{ text: "Session notes or a recording link", evidenceType: "LINK" }]);
  await api.call("POST", `/jobs/${draft.id}/fund`, poster.token);
  await deps.settle();
  const offer = (await getJobOrThrow(deps, draft.id)).currentOffer;
  await api.call("POST", `/offers/${offer?.offerId}/accept`, worker.token);
  const started = await api.call("POST", `/jobs/${draft.id}/start`, worker.token);
  const item = (started.body.checklist as Json[])[0];
  await api.call("POST", `/jobs/${draft.id}/proof`, worker.token, { items: [{ checklistItemId: item?.id, link: "https://notes.example.com/session" }] });
  await deps.settle();
  return { api, poster, worker, jobId: draft.id as string, itemId: item?.id as string };
}

test("the poster approves, both sides rate, and ratings show up on profiles", async () => {
  const deps = testDeps();
  const { api, poster, worker, jobId } = await inReview(deps);
  assert.equal((await api.call("POST", `/jobs/${jobId}/approve`, worker.token)).status, 403);
  const approved = await api.call("POST", `/jobs/${jobId}/approve`, poster.token);
  assert.equal(approved.body.status, "RELEASED");
  await deps.settle();

  await api.call("POST", `/jobs/${jobId}/rating`, poster.token, { stars: 5, comment: "Great session" });
  await api.call("POST", `/jobs/${jobId}/rating`, worker.token, { stars: 4 });
  assert.equal((await api.call("POST", `/jobs/${jobId}/rating`, poster.token, { stars: 1 })).body.error, "already_done");
  await deps.settle();

  const job = await api.call("GET", `/jobs/${jobId}`, poster.token);
  assert.equal(job.body.worker.rating, 5);
  assert.equal(job.body.poster.rating, 4);
  assert.deepEqual(job.body.allowedActions, []);
});

test("a dispute names an item; an admin resolves it", async () => {
  const deps = testDeps();
  const { api, poster, worker, jobId, itemId } = await inReview(deps);
  const disputed = await api.call("POST", `/jobs/${jobId}/dispute`, poster.token, { checklistItemId: itemId, note: "The link is empty" });
  assert.equal(disputed.body.status, "DISPUTED");
  assert.equal(disputed.body.dispute.itemId, itemId);

  assert.equal((await api.call("POST", `/jobs/${jobId}/resolve`, worker.token, { outcome: "release" })).status, 403);
  const admin = await api.login("admin");
  assert.equal(((await api.call("GET", `/jobs/${jobId}/proofs`, admin.token)).body as unknown as unknown[]).length, 1, "admins see the evidence");
  const resolved = await api.call("POST", `/jobs/${jobId}/resolve`, admin.token, { outcome: "refund", note: "Link was empty" });
  assert.equal(resolved.body.status, "REFUNDED");
  assert.equal(resolved.body.resolution.outcome, "refund");
  await deps.settle();
  assert.ok((await getJobOrThrow(deps, jobId)).payment.refundId);
});

test("the poster can reject work only after it failed review", async () => {
  const passing = testDeps();
  const first = await inReview(passing);
  assert.equal((await first.api.call("POST", `/jobs/${first.jobId}/reject`, first.poster.token)).body.error, "invalid_transition");

  // A grader that fails everything: after the worker's two retries, the poster may reject.
  const deps = testDeps();
  const fake = new FakeAi();
  deps.ai = Object.assign(fake, {
    grade: async (input: Parameters<FakeAi["grade"]>[0]) => ({
      ...(await new FakeAi().grade(input)),
      items: input.checklist.map((i) => ({ itemId: i.id, verdict: "fail" as const, confidence: 0.9, reason: "Link shows nothing" })),
    }),
  });
  const { api, poster, worker, jobId, itemId } = await inReview(deps);
  for (let attempt = 2; attempt <= 3; attempt++) {
    assert.equal((await getJobOrThrow(deps, jobId)).state, "IN_PROGRESS");
    await api.call("POST", `/jobs/${jobId}/proof`, worker.token, { items: [{ checklistItemId: itemId, link: `https://notes.example.com/try-${attempt}` }] });
    await deps.settle();
  }
  const job = await api.call("GET", `/jobs/${jobId}`, poster.token);
  assert.equal(job.body.status, "IN_REVIEW");
  assert.equal(job.body.review.requiresPosterAction, true);
  assert.deepEqual(job.body.allowedActions, ["approve", "reject", "dispute"]);
  const rejected = await api.call("POST", `/jobs/${jobId}/reject`, poster.token);
  assert.equal(rejected.body.status, "REFUNDED");
});
