import assert from "node:assert/strict";
import { FakeAi } from "../ai/fake.js";
import { test } from "node:test";
import type { Job, Proof } from "../domain/types.js";
import { codeMatches, decide } from "../services/grading.js";
import { applyEvent, getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn, type Json } from "../testing/api.js";
import { testDeps, type TestDeps } from "../testing/harness.js";

const SITE = { lat: 42.2808, lng: -83.743 };
const SYSTEM = { kind: "system" as const, source: "test" };

async function startedJob(deps: TestDeps, title = "Sketch a logo for a coffee shop") {
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const worker = await api.readyWorker("designer", { skill: "Logo design", ...SITE });
  const { body: created } = await api.call("POST", "/jobs", poster.token, {
    title,
    description: "Paper sketch of a logo for Bean There",
    category: "DESIGN",
    location: { latitude: SITE.lat, longitude: SITE.lng, address: "State St" },
    deadline: isoIn(deps, 6),
    payAmount: 15,
  });
  await applyEvent(deps, created.id, { type: "FUND_CONFIRMED", amountCents: 1650 }, SYSTEM);
  await deps.settle();
  const offer = (await getJobOrThrow(deps, created.id)).currentOffer;
  await api.call("POST", `/offers/${offer?.offerId}/accept`, worker.token);
  const started = await api.call("POST", `/jobs/${created.id}/start`, worker.token, { latitude: SITE.lat, longitude: SITE.lng });
  assert.equal(started.body.status, "IN_PROGRESS");
  assert.match(started.body.challengeCode, /^[A-Z0-9]{3}-[A-Z0-9]{3}$/);
  return { api, poster, worker, job: started.body as Json };
}

async function uploadPhoto(deps: TestDeps, api: ReturnType<typeof apiClient>, token: string, bytes: number[]) {
  const { body } = await api.call("POST", "/uploads/presign", token, { contentType: "image/jpeg" });
  await api.app.request(body.uploadURL.replace(deps.config.PUBLIC_BASE_URL, ""), { method: "PUT", headers: body.headers, body: new Uint8Array(bytes) });
  return body.fileURL as string;
}

async function fullProof(deps: TestDeps, api: ReturnType<typeof apiClient>, token: string, job: Json, seed: number) {
  const now = deps.now().toISOString();
  const items: Json[] = [];
  for (const item of job.checklist as Json[]) {
    if (item.evidenceType === "PHOTO") {
      const photos = [];
      for (let i = 0; i < item.photoCount; i++) photos.push({ fileURL: await uploadPhoto(deps, api, token, [seed, i, item.id.length]), capturedAt: now, latitude: SITE.lat, longitude: SITE.lng });
      items.push({ checklistItemId: item.id, photos });
    }
    if (item.evidenceType === "CHECK_IN") items.push({ checklistItemId: item.id, checkIn: { latitude: SITE.lat, longitude: SITE.lng, at: now } });
  }
  return items;
}

test("proof is checked, graded, reviewed, and auto-released when the window ends", async () => {
  const deps = testDeps();
  const { api, poster, worker, job } = await startedJob(deps);

  const items = await fullProof(deps, api, worker.token, job, 1);
  const pre = await api.call("POST", `/jobs/${job.id}/proof/precheck`, worker.token, { items });
  assert.equal(pre.body.checks.ok, true);

  const submitted = await api.call("POST", `/jobs/${job.id}/proof`, worker.token, { items });
  assert.equal(submitted.status, 200);
  assert.equal(submitted.body.status, "SUBMITTED");
  await deps.settle();

  const review = await api.call("GET", `/jobs/${job.id}`, poster.token);
  assert.equal(review.body.status, "IN_REVIEW");
  assert.ok(review.body.reviewDeadline);
  assert.ok(review.body.verdicts.length >= 2);
  assert.ok((review.body.verdicts as Json[]).every((v) => v.pass === true));
  assert.ok(review.body.proof.items.some((i: Json) => i.photoURLs.length > 0));
  assert.ok(deps.push.sent.some((p) => p.userId === poster.userId && p.message.type === "proof_ready"));
  assert.deepEqual(review.body.allowedActions, ["approve", "dispute"]);

  deps.clock.advance(deps.config.rules.reviewWindowSec + 1);
  await deps.settle();
  assert.equal((await getJobOrThrow(deps, job.id)).state, "RELEASED");
});

test("missing evidence blocks submission with the reasons", async () => {
  const deps = testDeps();
  const { api, worker, job } = await startedJob(deps);
  const photoItem = (job.checklist as Json[]).find((i) => i.evidenceType === "PHOTO");
  const res = await api.call("POST", `/jobs/${job.id}/proof`, worker.token, {
    items: [{ checklistItemId: photoItem?.id, photos: [{ fileURL: await uploadPhoto(deps, api, worker.token, [9]), capturedAt: "2020-01-01T00:00:00Z" }] }],
  });
  assert.equal(res.status, 422);
  assert.equal(res.body.error, "proof_incomplete");
  assert.ok(res.body.checks.missingRequired.length > 0);
  assert.deepEqual(res.body.checks.outsideTimeWindow, [photoItem?.id], "old photos are rejected");
  assert.equal((await getJobOrThrow(deps, job.id)).state, "IN_PROGRESS");
});

test("a photo used as proof for one job cannot be reused for another", async () => {
  const deps = testDeps();
  const first = await startedJob(deps);
  const items = await fullProof(deps, first.api, first.worker.token, first.job, 7);
  assert.equal((await first.api.call("POST", `/jobs/${first.job.id}/proof`, first.worker.token, { items })).status, 200);
  await deps.settle();

  // Same worker, a second job, the same image bytes uploaded again.
  const { body: second } = await first.api.call("POST", "/jobs", first.poster.token, {
    title: "Another sketch",
    description: "Second logo",
    category: "DESIGN",
    location: { latitude: SITE.lat, longitude: SITE.lng, address: "" },
    deadline: isoIn(deps, 6),
    payAmount: 15,
  });
  await applyEvent(deps, second.id, { type: "FUND_CONFIRMED", amountCents: 1650 }, SYSTEM);
  await deps.settle();
  const offer = (await getJobOrThrow(deps, second.id)).currentOffer;
  await first.api.call("POST", `/offers/${offer?.offerId}/accept`, first.worker.token);
  const started = await first.api.call("POST", `/jobs/${second.id}/start`, first.worker.token, { latitude: SITE.lat, longitude: SITE.lng });
  const reused = await fullProof(deps, first.api, first.worker.token, started.body, 7);
  const res = await first.api.call("POST", `/jobs/${second.id}/proof`, first.worker.token, { items: reused });
  assert.equal(res.status, 422);
  assert.ok(res.body.checks.duplicates.length > 0);
});

test("decision rules: confident fails fail, unsure or missing code goes to the poster", () => {
  const job = {
    checklist: [
      { id: "c1", text: "a", evidenceType: "PHOTO", photoCount: 1, required: true },
      { id: "c2", text: "b", evidenceType: "PHOTO", photoCount: 1, required: false },
    ],
  } as Job;
  const proof = { items: [{ checklistItemId: "c1", kind: "photo", phase: "single" }], checks: { outsideGeofence: [] } } as unknown as Proof;
  const v = (verdict: "pass" | "fail" | "unclear", confidence: number) => [{ itemId: "c1", verdict, confidence, reason: "" }];
  assert.equal(decide(job, proof, v("pass", 0.9), true).decision, "pass");
  assert.equal(decide(job, proof, v("fail", 0.8), true).decision, "fail");
  assert.equal(decide(job, proof, v("fail", 0.5), true).decision, "unclear");
  assert.equal(decide(job, proof, v("pass", 0.6), true).decision, "unclear");
  assert.equal(decide(job, proof, v("pass", 0.95), false).decision, "unclear", "code not visible");
  const away = { ...proof, checks: { outsideGeofence: ["c1"] } } as unknown as Proof;
  assert.equal(decide(job, away, v("pass", 0.95), true).decision, "unclear");
});

test("one image can't fill two photo slots or be both before and after", async () => {
  const deps = testDeps();
  const { api, worker, job } = await startedJob(deps);
  const photoItem = (job.checklist as Json[]).find((i) => i.evidenceType === "PHOTO");
  // Make the item need two photos and a before shot.
  const current = await getJobOrThrow(deps, job.id);
  await deps.store.saveJob(current.version, {
    ...current,
    checklist: current.checklist.map((i) => (i.id === photoItem?.id ? { ...i, photoCount: 2, beforeAfter: true } : i)),
    version: current.version + 1,
  });
  const now = deps.now().toISOString();
  const same = await uploadPhoto(deps, api, worker.token, [42]);
  const photo = (phase: string) => ({ fileURL: same, capturedAt: now, latitude: SITE.lat, longitude: SITE.lng, phase });
  const pre = await api.call("POST", `/jobs/${job.id}/proof/precheck`, worker.token, {
    items: [{ checklistItemId: photoItem?.id, photos: [photo("before"), photo("after"), photo("after")] }],
  });
  assert.ok(pre.body.checks.missingRequired.includes(photoItem?.id), "two copies of one image count once");
  assert.ok(pre.body.checks.duplicates.includes(photoItem?.id), "before and after can't be the same image");
});

test("a double-tapped submit goes through once", async () => {
  const deps = testDeps();
  const { api, worker, job } = await startedJob(deps);
  const items = await fullProof(deps, api, worker.token, job, 3);
  const [a, b] = await Promise.all([
    api.call("POST", `/jobs/${job.id}/proof`, worker.token, { items }),
    api.call("POST", `/jobs/${job.id}/proof`, worker.token, { items }),
  ]);
  assert.deepEqual([a.status, b.status].sort(), [200, 409]);
  await deps.settle();
  assert.equal((await deps.store.listProofs(job.id)).length, 1);
});

test("upload references must be the caller's own, in the exact presigned shape", async () => {
  const deps = testDeps();
  const { api, worker, job } = await startedJob(deps);
  const photoItem = (job.checklist as Json[]).find((i) => i.evidenceType === "PHOTO");
  const me = (await api.call("GET", "/me", worker.token)).body.userId as string;
  const sneaky = await api.call("POST", `/jobs/${job.id}/proof/precheck`, worker.token, {
    items: [{ checklistItemId: photoItem?.id, photos: [{ blobKey: `uploads/${me}/../someone/x.jpg`, capturedAt: deps.now().toISOString() }] }],
  });
  assert.equal(sneaky.status, 400);
  assert.equal(sneaky.body.error, "unknown_upload");
});

test("a worker who takes over a job doesn't see the previous worker's proofs", async () => {
  const deps = testDeps();
  const failing = new FakeAi();
  deps.ai = Object.assign(failing, {
    grade: async (input: Parameters<FakeAi["grade"]>[0]) => ({
      ...(await new FakeAi().grade(input)),
      items: input.checklist.map((i) => ({ itemId: i.id, verdict: "fail" as const, confidence: 0.9, reason: "No" })),
    }),
  });
  const { api, poster, worker, job } = await startedJob(deps);
  const next = await api.readyWorker("second", { skill: "Logo design", ...SITE });
  await api.call("POST", `/jobs/${job.id}/proof`, worker.token, { items: await fullProof(deps, api, worker.token, job, 5) });
  await deps.settle();
  assert.equal((await api.call("POST", `/jobs/${job.id}/withdraw`, worker.token)).status, 204);
  await deps.settle();
  const offer = (await getJobOrThrow(deps, job.id)).currentOffer;
  assert.equal(offer?.workerId, next.userId);
  await api.call("POST", `/offers/${offer?.offerId}/accept`, next.token);
  assert.deepEqual((await api.call("GET", `/jobs/${job.id}/proofs`, next.token)).body, []);
  assert.equal(((await api.call("GET", `/jobs/${job.id}/proofs`, poster.token)).body as unknown as Json[]).length, 1);
});

test("the one-time code must actually match what the model read", async () => {
  assert.equal(codeMatches("K7Q-4MX", "K7Q-4MX"), true);
  assert.equal(codeMatches("k7q 4mx", "K7Q-4MX"), true, "case and separators don't matter");
  assert.equal(codeMatches("K7Q4NX", "K7Q-4MX"), true, "one misread character is tolerated");
  assert.equal(codeMatches("K7Q4M", "K7Q-4MX"), true, "one missing character is tolerated");
  assert.equal(codeMatches("ABC-DEF", "K7Q-4MX"), false);
  assert.equal(codeMatches("", "K7Q-4MX"), false);
});
