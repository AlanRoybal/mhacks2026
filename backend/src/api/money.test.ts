import assert from "node:assert/strict";
import { test } from "node:test";
import { getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn, type Json } from "../testing/api.js";
import { testDeps } from "../testing/harness.js";

const SITE = { lat: 42.2808, lng: -83.743 };

// A $20 remote job taken from posting to paid on the fake rail: funded, accepted, proof submitted,
// approved by the poster, payout confirmed.
async function paidJob() {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const worker = await api.readyWorker("reviewer", { skill: "Résumé review and editing", ...SITE });
  await api.call("PATCH", "/me", worker.token, { displayName: "Alan Roybal" });
  const { body: draft } = await api.call("POST", "/jobs", poster.token, {
    title: "Fix a bug in my portfolio site",
    description: "The contact form doesn't send. Fix it and share the commit link.",
    category: "TECHNOLOGY",
    location: null,
    deadline: isoIn(deps, 8),
    payAmount: 20,
  });
  await api.call("POST", `/jobs/${draft.id}/fund`, poster.token);
  await deps.settle();
  const offer = (await getJobOrThrow(deps, draft.id)).currentOffer;
  await api.call("POST", `/offers/${offer?.offerId}/accept`, worker.token);
  const started = await api.call("POST", `/jobs/${draft.id}/start`, worker.token);
  const items: Json[] = [];
  for (const item of started.body.checklist as Json[]) {
    if (item.evidenceType === "LINK") items.push({ checklistItemId: item.id, link: "https://github.com/me/site/commit/abc123" });
    if (item.evidenceType === "FILE") {
      const { body: upload } = await api.call("POST", "/uploads/presign", worker.token, { contentType: "application/pdf" });
      await api.app.request(upload.uploadURL.replace(deps.config.PUBLIC_BASE_URL, ""), { method: "PUT", headers: upload.headers, body: new Uint8Array([37, 80, 68, 70]) });
      items.push({ checklistItemId: item.id, files: [{ fileURL: upload.fileURL }] });
    }
  }
  assert.equal((await api.call("POST", `/jobs/${draft.id}/proof`, worker.token, { items })).status, 200);
  await deps.settle();
  deps.clock.advance(5);
  assert.equal((await api.call("POST", `/jobs/${draft.id}/approve`, poster.token)).status, 200);
  await deps.settle();
  assert.equal((await getJobOrThrow(deps, draft.id)).state, "RELEASED");
  return { deps, api, poster, worker, jobId: draft.id as string };
}

test("follow the money: charged, held, released and paid, each with its reference", async () => {
  const { api, poster, worker, jobId } = await paidJob();
  const asPoster = (await api.call("GET", `/jobs/${jobId}/money`, poster.token)).body;
  assert.deepEqual(asPoster.steps.map((s: Json) => s.kind), ["charged", "held", "released", "paid"]);
  assert.equal(asPoster.steps[0].label, "Charged $22");
  assert.equal(asPoster.steps[0].detail, "$20 job pay + $2 Bounty fee");
  assert.equal(asPoster.steps[2].detail, "The poster approved the work");
  assert.equal(asPoster.steps[3].reference, `fake_tr_${jobId}`);
  assert.equal(asPoster.timeToPaidSeconds, 0);

  const asWorker = (await api.call("GET", `/jobs/${jobId}/money`, worker.token)).body;
  assert.equal(asWorker.steps[0].label, "$20 paid in by the poster");
  assert.equal(asWorker.steps[3].label, "$20 paid to you");

  const stranger = await api.login("stranger");
  assert.equal((await api.call("GET", `/jobs/${jobId}/money`, stranger.token)).status, 404);
});

test("earnings show time to paid, year-to-date income and the tax set-aside", async () => {
  const { api, worker } = await paidJob();
  const before = (await api.call("GET", "/wallet/earnings", worker.token)).body;
  assert.equal(before.yearToDatePaid, 20);
  assert.equal(before.averageTimeToPaidSeconds, 0);
  assert.deepEqual(before.taxSetAside, { percent: 0, amount: 0 });
  assert.equal(before.items[0].timeToPaidSeconds, 0);

  const after = (await api.call("PUT", "/wallet/tax", worker.token, { percent: 25 })).body;
  assert.deepEqual(after.taxSetAside, { percent: 25, amount: 5 });
  assert.equal((await api.call("PUT", "/wallet/tax", worker.token, { percent: 80 })).status, 400);
});

test("an income statement lists paid work and anyone with the link can verify it", async () => {
  const { deps, api, worker } = await paidJob();
  const statement = (await api.call("POST", "/wallet/income-statement", worker.token, { period: "year" })).body;
  assert.equal(statement.workerName, "Alan Roybal");
  assert.equal(statement.totalPaid, 20);
  assert.equal(statement.jobCount, 1);
  assert.equal(statement.jobs[0].title, "Fix a bug in my portfolio site");
  assert.ok(statement.verifyUrl.startsWith(`${deps.config.PUBLIC_BASE_URL}/verify/income/`));

  const page = await api.app.request(statement.verifyUrl.replace(deps.config.PUBLIC_BASE_URL, ""));
  assert.equal(page.status, 200);
  const html = await page.text();
  assert.match(html, /Verified by Bounty/);
  assert.match(html, /Alan Roybal/);
  assert.match(html, /\$20\.00/);

  const missing = await api.app.request("/verify/income/not-a-real-statement");
  assert.equal(missing.status, 404);
  assert.match(await missing.text(), /Statement not found/);
});
