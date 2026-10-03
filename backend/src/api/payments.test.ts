import assert from "node:assert/strict";
import { test } from "node:test";
import { getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn, type Json } from "../testing/api.js";
import { testDeps, type TestDeps } from "../testing/harness.js";

const SITE = { lat: 42.2808, lng: -83.743 };

function draftBody(deps: TestDeps, overrides: Json = {}) {
  return {
    title: "Fix a bug in my portfolio site",
    description: "The contact form doesn't send. Fix it and share the commit link.",
    category: "TECHNOLOGY",
    location: null,
    deadline: isoIn(deps, 8),
    payAmount: 20,
    ...overrides,
  };
}

test("fake rail: fund, work, approve, pay out, and show earnings", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const worker = await api.readyWorker("reviewer", { skill: "Résumé review and editing", ...SITE });
  const { body: draft } = await api.call("POST", "/jobs", poster.token, draftBody(deps));

  const fund = await api.call("POST", `/jobs/${draft.id}/fund`, poster.token);
  assert.equal(fund.status, 200);
  assert.equal(fund.body.provider, "fake");
  assert.ok(fund.body.paymentIntentClientSecret);
  assert.equal(fund.body.job.status, "FUNDED");
  await deps.settle();

  const offer = (await getJobOrThrow(deps, draft.id)).currentOffer;
  assert.equal(offer?.workerId, worker.userId);
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
  const submitted = await api.call("POST", `/jobs/${draft.id}/proof`, worker.token, { items });
  assert.equal(submitted.status, 200, JSON.stringify(submitted.body));
  await deps.settle();

  // Nobody responds during the review window, so the money releases automatically (US-47).
  deps.clock.advance(deps.config.rules.reviewWindowSec + 1);
  await deps.settle();

  const job = await getJobOrThrow(deps, draft.id);
  assert.equal(job.state, "RELEASED");
  assert.equal(job.payment.transferId, `fake_tr_${draft.id}`);
  assert.ok(deps.push.sent.some((p) => p.userId === worker.userId && p.message.type === "paid"));

  const earnings = await api.call("GET", "/wallet/earnings", worker.token);
  assert.equal(earnings.body.available, 20);
  assert.equal(earnings.body.pending, 0);
  assert.equal(earnings.body.items[0].status, "paid");
});

test("canceling a funded job refunds the poster", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const { body: draft } = await api.call("POST", "/jobs", poster.token, draftBody(deps));
  await api.call("POST", `/jobs/${draft.id}/fund`, poster.token);
  await deps.settle();
  const canceled = await api.call("POST", `/jobs/${draft.id}/cancel`, poster.token);
  assert.equal(canceled.body.status, "REFUNDED");
  await deps.settle();
  const job = await getJobOrThrow(deps, draft.id);
  assert.equal(job.payment.refundId, `fake_re_${draft.id}`);
  assert.ok(deps.push.sent.some((p) => p.userId === poster.userId && p.message.type === "refunded"));
  const again = await api.call("POST", `/jobs/${draft.id}/fund`, poster.token);
  assert.equal(again.body.error, "already_funded");
});

test("USDC jobs cannot be funded until that rail exists", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const { body: draft } = await api.call("POST", "/jobs", poster.token, draftBody(deps, { currency: "USDC" }));
  const fund = await api.call("POST", `/jobs/${draft.id}/fund`, poster.token);
  assert.equal(fund.status, 501);
  assert.equal(fund.body.error, "rail_unavailable");
});

test("a signed Stripe webhook funds the job once", async () => {
  const deps = testDeps({ STRIPE_SECRET_KEY: "sk_test_123", STRIPE_PUBLISHABLE_KEY: "pk_test_123", STRIPE_WEBHOOK_SECRET: "whsec_test" });
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const { body: draft } = await api.call("POST", "/jobs", poster.token, draftBody(deps));
  const stripe = deps.payments.stripe;
  assert.ok(stripe);

  const payload = JSON.stringify({
    id: "evt_1",
    object: "event",
    type: "payment_intent.succeeded",
    data: { object: { id: "pi_1", object: "payment_intent", amount_received: 2200, latest_charge: "ch_1", metadata: { jobId: draft.id } } },
  });
  const send = async (body: string, signature: string) =>
    api.app.request("/webhooks/stripe", { method: "POST", headers: { "content-type": "application/json", "stripe-signature": signature }, body });

  assert.equal((await send(payload, "t=1,v1=bad")).status, 400);
  const header = stripe.stripe.webhooks.generateTestHeaderString({ payload, secret: "whsec_test" });
  assert.equal((await send(payload, header)).status, 200);
  assert.equal((await send(payload, header)).status, 200, "duplicate deliveries are fine");

  const job = await getJobOrThrow(deps, draft.id);
  assert.equal(job.state, "FUNDED");
  assert.equal(job.payment.paymentIntentId, "pi_1");
  assert.equal(job.payment.chargeId, "ch_1");
  assert.equal((await deps.store.listLedger(draft.id)).filter((e) => e.type === "FUND_CONFIRMED").length, 1);
});
