import assert from "node:assert/strict";
import { FakeAi } from "../ai/fake.js";
import { test } from "node:test";
import type { Job, Proof } from "../domain/types.js";
import { sha256Hex, signCapture } from "../services/capture.js";
import { decide } from "../services/grading.js";
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
  const started = await api.call("POST", `/jobs/${created.id}/start`, worker.token, { latitude: SITE.lat, longitude: SITE.lng, accuracyM: 9 });
  assert.equal(started.body.status, "IN_PROGRESS");
  assert.deepEqual({ ...started.body.startCheck, at: undefined }, { distanceM: 0, accuracyM: 9, at: undefined }, "the start check reaches the app");
  assert.match(started.body.captureKey, /^[A-Za-z0-9_-]{43}$/);
  return { api, poster, worker, job: started.body as Json };
}

async function uploadPhoto(deps: TestDeps, api: ReturnType<typeof apiClient>, token: string, bytes: number[]) {
  const { body } = await api.call("POST", "/uploads/presign", token, { contentType: "image/jpeg" });
  await api.app.request(body.uploadURL.replace(deps.config.PUBLIC_BASE_URL, ""), { method: "PUT", headers: body.headers, body: new Uint8Array(bytes) });
  return body.fileURL as string;
}

// What the app sends for a photo taken with the Bounty camera: the upload, plus its signed fingerprint.
async function capturedPhoto(deps: TestDeps, api: ReturnType<typeof apiClient>, token: string, job: Json, bytes: number[], extra: Json = {}) {
  const capturedAt = deps.now().toISOString();
  const sha256 = sha256Hex(Buffer.from(bytes));
  const signature = signCapture(job.captureKey, { jobId: job.id, sha256, capturedAt, lat: SITE.lat, lng: SITE.lng });
  return { fileURL: await uploadPhoto(deps, api, token, bytes), capturedAt, latitude: SITE.lat, longitude: SITE.lng, sha256, signature, ...extra };
}

async function fullProof(deps: TestDeps, api: ReturnType<typeof apiClient>, token: string, job: Json, seed: number) {
  const now = deps.now().toISOString();
  const items: Json[] = [];
  for (const item of job.checklist as Json[]) {
    if (item.evidenceType === "PHOTO") {
      const photos = [];
      for (let i = 0; i < item.photoCount; i++) photos.push(await capturedPhoto(deps, api, token, job, [seed, i, item.id.length]));
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
  assert.equal(res.body.error.code, "proof_incomplete");
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

test("decision rules: confident fails fail, unsure or away from the job goes to the poster", () => {
  const job = {
    checklist: [
      { id: "c1", text: "a", evidenceType: "PHOTO", photoCount: 1, required: true },
      { id: "c2", text: "b", evidenceType: "PHOTO", photoCount: 1, required: false },
    ],
  } as Job;
  const proof = { items: [{ checklistItemId: "c1", kind: "photo", phase: "single" }], checks: { outsideGeofence: [] } } as unknown as Proof;
  const v = (verdict: "pass" | "fail" | "unclear", confidence: number) => [{ itemId: "c1", verdict, confidence, reason: "" }];
  assert.equal(decide(job, proof, v("pass", 0.9)).decision, "pass");
  assert.equal(decide(job, proof, v("fail", 0.8)).decision, "fail");
  assert.equal(decide(job, proof, v("fail", 0.5)).decision, "unclear");
  assert.equal(decide(job, proof, v("pass", 0.6)).decision, "unclear");
  const away = { ...proof, checks: { outsideGeofence: ["c1"] } } as unknown as Proof;
  assert.equal(decide(job, away, v("pass", 0.95)).decision, "unclear");
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
  assert.equal(sneaky.body.error.code, "unknown_upload");
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

test("only photos taken with the Bounty camera for this job count", async () => {
  const deps = testDeps();
  const { api, worker, job } = await startedJob(deps);
  const items = await fullProof(deps, api, worker.token, job, 7);
  const photoItem = items.find((i) => i.photos);
  assert.ok(photoItem);
  const check = async () => (await api.call("POST", `/jobs/${job.id}/proof/precheck`, worker.token, { items })).body.checks;

  // From the camera roll: no signature.
  const [signed] = photoItem.photos;
  photoItem.photos = [{ fileURL: signed.fileURL, capturedAt: signed.capturedAt, latitude: SITE.lat, longitude: SITE.lng }];
  assert.deepEqual((await check()).notCapturedInApp, [photoItem.checklistItemId]);

  // Signed, but the uploaded bytes aren't the ones that were signed (edited after capture).
  photoItem.photos = [{ ...signed, fileURL: await uploadPhoto(deps, api, worker.token, [9, 9, 9]) }];
  assert.deepEqual((await check()).notCapturedInApp, [photoItem.checklistItemId]);

  // Signed with a key from another job.
  const elsewhere = await capturedPhoto(deps, api, worker.token, { ...job, id: "another-job" }, [4, 5, 6]);
  photoItem.photos = [elsewhere];
  assert.deepEqual((await check()).notCapturedInApp, [photoItem.checklistItemId]);

  // A moved GPS fix breaks the signature too.
  photoItem.photos = [{ ...signed, latitude: SITE.lat + 0.01 }];
  assert.deepEqual((await check()).notCapturedInApp, [photoItem.checklistItemId]);

  photoItem.photos = [signed];
  const ok = await check();
  assert.equal(ok.ok, true);
  assert.deepEqual(ok.notCapturedInApp, []);
});

test("a short in-app video can stand in for an item's photos", async () => {
  const deps = testDeps();
  const { api, poster, worker, job } = await startedJob(deps);
  const items = await fullProof(deps, api, worker.token, job, 11);
  const photoItem = items.find((i) => i.photos);
  assert.ok(photoItem);

  // The app records the clip, pulls three stills from it, and signs the clip and each still.
  const { body: upload } = await api.call("POST", "/uploads/presign", worker.token, { contentType: "video/quicktime" });
  const clip = [0x00, 0x00, 0x00, 0x14, 0x66, 0x74, 0x79, 0x70, 11];
  await api.app.request(upload.uploadURL.replace(deps.config.PUBLIC_BASE_URL, ""), { method: "PUT", headers: upload.headers, body: new Uint8Array(clip) });
  const signedClip = await capturedPhoto(deps, api, worker.token, job, clip);
  const frames = [];
  for (const n of [1, 2, 3]) {
    const frame = await capturedPhoto(deps, api, worker.token, job, [77, n]);
    frames.push({ fileURL: frame.fileURL, sha256: frame.sha256, signature: frame.signature });
  }
  const video = { ...signedClip, fileURL: upload.fileURL, frames };
  delete photoItem.photos;
  photoItem.videos = [video];

  const pre = await api.call("POST", `/jobs/${job.id}/proof/precheck`, worker.token, { items });
  assert.equal(pre.body.checks.ok, true, JSON.stringify(pre.body.checks));

  const unsigned = await api.call("POST", `/jobs/${job.id}/proof/precheck`, worker.token, {
    items: items.map((i) => (i === photoItem ? { ...i, videos: [{ ...video, signature: undefined }] } : i)),
  });
  assert.deepEqual(unsigned.body.checks.notCapturedInApp, [photoItem.checklistItemId]);

  assert.equal((await api.call("POST", `/jobs/${job.id}/proof`, worker.token, { items })).status, 200);
  await deps.settle();
  const review = await api.call("GET", `/jobs/${job.id}`, poster.token);
  assert.equal(review.body.status, "IN_REVIEW");
  const shown = (review.body.proof.items as Json[]).find((i) => i.checklistItemId === photoItem.checklistItemId);
  assert.equal(shown?.videoURLs.length, 1, "the poster can watch the clip");
  assert.deepEqual(shown?.photoURLs, [], "its stills aren't listed as separate photos");
});
