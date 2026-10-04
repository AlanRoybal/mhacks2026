// The risk engine in the product: exposure limits in matching, risk on the poster's job view, the
// worker's trust score and the admin reserve report.

import assert from "node:assert/strict";
import { test } from "node:test";
import { applyEvent, getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn, type Json } from "../testing/api.js";
import { testDeps } from "../testing/harness.js";

const SITE = { lat: 42.2808, lng: -83.743 };
const SYSTEM = { kind: "system" as const, source: "test" };

async function fundedJob(api: ReturnType<typeof apiClient>, deps: ReturnType<typeof testDeps>, token: string, payAmount: number) {
  const { body } = await api.call("POST", "/jobs", token, {
    title: "Design a lost cat flyer",
    description: "Flyer with the photo, my number and REWARD",
    category: "DESIGN",
    location: null,
    deadline: isoIn(deps, 6),
    payAmount,
  });
  await applyEvent(deps, body.id, { type: "FUND_CONFIRMED", amountCents: Math.round(payAmount * 110) }, SYSTEM);
  await deps.settle();
  return body.id as string;
}

test("a brand-new worker's exposure limit keeps a $200 escrow away from them, not a $40 one", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const worker = await api.readyWorker("designer", { skill: "Flyer design", ...SITE });

  const trust = await api.call("GET", "/me/trust", worker.token);
  assert.deepEqual({ limit: trust.body.exposureLimit, open: trust.body.openExposure }, { limit: 50, open: 0 });

  const big = await fundedJob(api, deps, poster.token, 200);
  assert.equal((await getJobOrThrow(deps, big)).currentOffer, undefined, "over the limit: not offered");

  const small = await fundedJob(api, deps, poster.token, 40);
  assert.equal((await getJobOrThrow(deps, small)).currentOffer?.workerId, worker.userId);
});

test("the poster sees the escrow's risk, and admins get the reserve report", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  await api.readyWorker("designer", { skill: "Flyer design", ...SITE });
  const jobId = await fundedJob(api, deps, poster.token, 40);

  const view = await api.call("GET", `/jobs/${jobId}`, poster.token);
  const risk = view.body.risk as Json;
  assert.match(risk.tier, /^[A-E]$/);
  assert.equal(risk.exposure, 40);
  assert.ok(risk.expectedLoss > 0 && risk.expectedLoss < 40);
  assert.ok(Math.abs(risk.probabilityOfLoss * risk.lossGivenDefault * risk.exposure - risk.expectedLoss) < 0.02, "EL = PD x LGD x EAD");

  const admin = await api.login("admin");
  const report = await api.call("GET", "/admin/risk", admin.token);
  assert.equal(report.status, 200);
  assert.equal(report.body.escrows, 1);
  assert.equal(report.body.exposureCents, 4000);
  const p = report.body.portfolio as Json;
  assert.ok(p.expectedLossCents <= p.var99Cents && p.var99Cents <= p.es99Cents);
  assert.equal(report.body.riskiest[0].jobId, jobId);
  assert.equal((await api.call("GET", "/admin/risk", poster.token)).status, 403);
});
