// The payments checkout's contract (PaymentCheckoutView.swift): POST /payment-sheet and GET /jobs/<uuid>.

import assert from "node:assert/strict";
import { randomUUID } from "node:crypto";
import { test } from "node:test";
import type Stripe from "stripe";
import { getJobOrThrow } from "../services/jobs.js";
import { apiClient } from "../testing/api.js";
import { testDeps, type TestDeps } from "../testing/harness.js";

const iso = (deps: TestDeps, hours: number) => new Date(deps.now().getTime() + hours * 3600_000).toISOString();

// What FundingDraft encodes to (JSONEncoder, no session header).
function fundingDraft(deps: TestDeps, overrides: Record<string, unknown> = {}) {
  return {
    id: randomUUID().toUpperCase(),
    title: "Sketch a logo for a coffee shop",
    details: "Paper sketch of a logo for Bean There",
    category: "Design",
    isRemote: true,
    deadline: iso(deps, 6),
    amountCents: 1500,
    ...overrides,
  };
}

async function post(api: ReturnType<typeof apiClient>, path: string, body: unknown, headers: Record<string, string> = {}) {
  const res = await api.app.request(path, { method: "POST", headers: { "content-type": "application/json", ...headers }, body: JSON.stringify(body) });
  return { status: res.status, body: (await res.json()) as Record<string, any> };
}

test("local checkout funds a real job that then gets matched", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const worker = await api.readyWorker("designer", { skill: "Logo design", lat: 42.28, lng: -83.74 });
  const draft = fundingDraft(deps);

  const sheet = await post(api, "/payment-sheet", draft);
  assert.equal(sheet.status, 200, JSON.stringify(sheet.body));
  assert.equal(sheet.body.publishableKey, "pk_test_fake", "the app requires a test-mode key");
  assert.ok(typeof sheet.body.paymentIntentClientSecret === "string");
  assert.equal(sheet.body.job.id, draft.id.toLowerCase());
  assert.equal(sheet.body.job.status, "funded");
  assert.equal(sheet.body.job.totalCents, 1650);
  assert.match(sheet.body.job.deadline, /\.\d{3}Z$/, "fractional seconds, as the app parses them");

  await deps.settle();
  assert.equal((await getJobOrThrow(deps, draft.id.toLowerCase())).currentOffer?.workerId, worker.userId);

  const again = await post(api, "/payment-sheet", draft);
  assert.equal(again.body.job.status, "funded", "a retried checkout reuses the job");

  const status = await api.app.request(`/jobs/${draft.id.toLowerCase()}`);
  assert.equal(((await status.json()) as { status: string }).status, "funded");

  const authed = await api.call("GET", `/jobs/${draft.id.toLowerCase()}`, worker.token);
  assert.equal(authed.body.status, "OFFERED", "with a session, the normal job view answers");
});

test("errors use the checkout's { error: message } format", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const cheap = await post(api, "/payment-sheet", fundingDraft(deps, { amountCents: 100 }));
  assert.deepEqual(cheap, { status: 400, body: { error: "Pay must be between $5 and $1000" } });
  const bad = await post(api, "/payment-sheet", { id: "nope" });
  assert.equal(bad.status, 400);
  assert.equal(typeof bad.body.error, "string");
  const missing = await api.app.request(`/jobs/${randomUUID()}`);
  assert.equal(missing.status, 404);
});

test("deployed stages need a session to post", async () => {
  const deps = testDeps({ STAGE: "dev", JWT_SECRET: "x".repeat(40) });
  const api = apiClient(deps);
  assert.deepEqual(await post(api, "/payment-sheet", fundingDraft(deps)), { status: 401, body: { error: "Sign in to post a job." } });
});

test("with Stripe, the status poll confirms payment without a webhook", async () => {
  const deps = testDeps({ PAYMENTS_PROVIDER: "stripe", STRIPE_SECRET_KEY: "sk_test_123", STRIPE_PUBLISHABLE_KEY: "pk_test_123", STRIPE_WEBHOOK_SECRET: "whsec_x" });
  const api = apiClient(deps);
  const stripe = deps.payments.stripe;
  assert.ok(stripe);
  const draft = fundingDraft(deps);
  const jobId = draft.id.toLowerCase();
  stripe.startFunding = async () => ({
    provider: "stripe",
    paymentIntentId: "pi_123",
    paymentIntentClientSecret: "pi_123_secret_abc",
    customerId: null,
    ephemeralKeySecret: null,
    publishableKey: "pk_test_123",
  });
  let paid = false;
  stripe.stripe.paymentIntents.retrieve = (async () =>
    ({
      id: "pi_123",
      status: paid ? "succeeded" : "requires_payment_method",
      amount_received: paid ? 1650 : 0,
      latest_charge: "ch_123",
      metadata: { jobId },
    }) as unknown as Stripe.PaymentIntent) as unknown as typeof stripe.stripe.paymentIntents.retrieve;

  const sheet = await post(api, "/payment-sheet", draft);
  assert.equal(sheet.body.paymentIntentClientSecret, "pi_123_secret_abc");
  assert.equal(sheet.body.job.status, "draft");

  const before = await api.app.request(`/jobs/${jobId}`);
  assert.equal(((await before.json()) as { status: string }).status, "draft");
  paid = true;
  const after = await api.app.request(`/jobs/${jobId}`);
  assert.equal(((await after.json()) as { status: string }).status, "funded");
  assert.equal((await getJobOrThrow(deps, jobId)).payment.chargeId, "ch_123");
});
