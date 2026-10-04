// Live job sessions (SpacetimeDB; MemoryLive here, with the module's rules): on-site time from pings,
// leaving the site, signal loss, Live Activity pushes, and proof that depends on time on site.

import assert from "node:assert/strict";
import { test } from "node:test";
import { sha256Hex, signCapture } from "../services/capture.js";
import { applyEvent, getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn, type Json } from "../testing/api.js";
import { testDeps, type TestDeps } from "../testing/harness.js";

const SITE = { lat: 42.2808, lng: -83.743 };
const AWAY = { lat: 42.2908, lng: -83.743 }; // about 1.1 km north
const SYSTEM = { kind: "system" as const, source: "test" };

async function startedMowing(deps: TestDeps) {
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const worker = await api.readyWorker("mower", { skill: "Lawn mowing", ...SITE });
  const { body } = await api.call("POST", "/jobs", poster.token, {
    title: "Mow my front lawn",
    description: "Front yard only, bag the clippings",
    category: "YARD_WORK",
    location: { latitude: SITE.lat, longitude: SITE.lng, address: "1200 S University Ave" },
    deadline: isoIn(deps, 6),
    payAmount: 40,
  });
  await applyEvent(deps, body.id, { type: "FUND_CONFIRMED", amountCents: 4400 }, SYSTEM);
  await deps.settle();
  const offer = (await getJobOrThrow(deps, body.id)).currentOffer;
  await api.call("POST", `/offers/${offer?.offerId}/accept`, worker.token);
  const started = await api.call("POST", `/jobs/${body.id}/start`, worker.token, { latitude: SITE.lat, longitude: SITE.lng, accuracyM: 6 });
  await deps.settle();
  return { api, poster, worker, job: started.body as Json };
}

const ping = (api: ReturnType<typeof apiClient>, token: string, jobId: string, at: { lat: number; lng: number }, accuracyM = 8) =>
  api.call("POST", `/jobs/${jobId}/live/ping`, token, { latitude: at.lat, longitude: at.lng, accuracyM });

test("starting opens a live session on site; leaving pauses the clock and coming back resumes it", async () => {
  const deps = testDeps();
  const { api, poster, worker, job } = await startedMowing(deps);

  let live = (await api.call("GET", `/jobs/${job.id}/live`, poster.token)).body;
  assert.equal(live.phase, "on_site");
  assert.equal(live.provider, "memory");
  assert.ok(live.timerStartEpoch, "the Live Activity can tick a timer from here");

  deps.clock.advance(60);
  await ping(api, worker.token, job.id, SITE);
  deps.clock.advance(60);
  live = (await ping(api, worker.token, job.id, AWAY)).body;
  assert.equal(live.phase, "away");
  assert.equal(live.onSiteSeconds, 120);
  assert.equal(live.leftSiteCount, 1);
  assert.equal(live.timerStartEpoch, null, "the timer stops while away");

  deps.clock.advance(60);
  live = (await ping(api, worker.token, job.id, SITE)).body;
  assert.equal(live.phase, "on_site");
  deps.clock.advance(30);
  live = (await api.call("GET", `/jobs/${job.id}/live`, worker.token)).body;
  assert.equal(live.onSiteSeconds, 150, "the minute away doesn't count");
  assert.deepEqual((live.events as Json[]).map((e) => e.kind), ["arrived", "left", "arrived"]);

  // A vague fix (GPS worse than the radius) can't move anyone off site.
  live = (await ping(api, worker.token, job.id, AWAY, 900)).body;
  assert.equal(live.phase, "on_site");
});

test("when pings stop, on-site time stops at the last one", async () => {
  const deps = testDeps();
  const { api, worker, job } = await startedMowing(deps);
  deps.clock.advance(60);
  await ping(api, worker.token, job.id, SITE);
  deps.clock.advance(10 * 60); // phone in a pocket with the app closed
  const live = (await api.call("GET", `/jobs/${job.id}/live`, worker.token)).body;
  assert.equal(live.onSiteSeconds, 60);
});

test("Live Activities get updates on changes, and the end when the job is paid", async () => {
  const deps = testDeps();
  const { api, poster, worker, job } = await startedMowing(deps);
  const token = "ab".repeat(32);
  assert.equal((await api.call("POST", `/jobs/${job.id}/live/activity`, worker.token, { token, env: "sandbox", role: "poster" })).status, 403);
  assert.equal((await api.call("POST", `/jobs/${job.id}/live/activity`, poster.token, { token, env: "sandbox", role: "poster" })).status, 204);
  assert.equal(deps.push.liveActivities.at(-1)?.contentState.phase, "on_site", "registered activities are brought up to date");

  await ping(api, worker.token, job.id, AWAY);
  const update = deps.push.liveActivities.at(-1);
  assert.equal(update?.contentState.phase, "away");
  assert.match(update?.alert?.body ?? "", /Left the job site/);

  const sent = deps.push.liveActivities.length;
  await ping(api, worker.token, job.id, AWAY);
  assert.equal(deps.push.liveActivities.length, sent, "no push when nothing changed");

  await applyEvent(deps, job.id, { type: "WITHDRAW" }, { kind: "user", userId: worker.userId });
  await deps.settle();
  assert.equal(deps.push.liveActivities.at(-1)?.event, "end");
});

test("in-person proof after too little time on site goes to the poster, not to auto-pay", async () => {
  const deps = testDeps();
  const { api, poster, worker, job } = await startedMowing(deps);
  deps.clock.advance(60);
  const items: Json[] = [];
  for (const item of job.checklist as Json[]) {
    if (item.evidenceType === "CHECK_IN") items.push({ checklistItemId: item.id, checkIn: { latitude: SITE.lat, longitude: SITE.lng, at: deps.now().toISOString() } });
    if (item.evidenceType !== "PHOTO") continue;
    const photos: Json[] = [];
    for (let i = 0; i < (item.photoCount ?? 1) + (item.beforeAfter ? 1 : 0); i++) {
      const bytes = Buffer.from([7, i, item.id.length]);
      const capturedAt = deps.now().toISOString();
      const sha256 = sha256Hex(bytes);
      const { body: up } = await api.call("POST", "/uploads/presign", worker.token, { contentType: "image/jpeg" });
      await api.app.request(up.uploadURL.replace(deps.config.PUBLIC_BASE_URL, ""), { method: "PUT", headers: up.headers, body: new Uint8Array(bytes) });
      const signature = signCapture(job.captureKey, { jobId: job.id, sha256, capturedAt, lat: SITE.lat, lng: SITE.lng });
      photos.push({ fileURL: up.fileURL, capturedAt, latitude: SITE.lat, longitude: SITE.lng, sha256, signature, phase: item.beforeAfter && i === 0 ? "before" : "after" });
    }
    items.push({ checklistItemId: item.id, photos });
  }
  const pre = await api.call("POST", `/jobs/${job.id}/proof/precheck`, worker.token, { items });
  assert.equal(pre.body.checks.ok, true, JSON.stringify(pre.body.checks));
  assert.ok(pre.body.checks.onSite.seconds < pre.body.checks.onSite.requiredSeconds);
  assert.ok((pre.body.checks.warnings as string[]).some((w) => /min on site/.test(w)));

  assert.equal((await api.call("POST", `/jobs/${job.id}/proof`, worker.token, { items })).status, 200);
  await deps.settle();
  const graded = await api.call("GET", `/jobs/${job.id}`, poster.token);
  assert.equal(graded.body.review.requiresPosterAction, true);
  assert.match((await api.call("GET", `/jobs/${job.id}/proofs`, poster.token)).body[0].decidedBecause, /minutes on site/);
  assert.equal((await api.call("GET", `/jobs/${job.id}/live`, poster.token)).body.phase, "in_review");
});

test("only the assigned worker pings, and only while the job is in progress", async () => {
  const deps = testDeps();
  const { api, poster, job } = await startedMowing(deps);
  assert.equal((await ping(api, poster.token, job.id, SITE)).status, 403);
});
