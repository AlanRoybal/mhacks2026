// Real Stripe API, test mode only. Uses synthetic Stripe verification fixtures.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { setTimeout as delay } from 'node:timers/promises';
import Stripe from 'stripe';
import { JobStore, Payments } from './payments.mjs';
import { Workers } from './workers.mjs';
import { Settlements } from './settlements.mjs';
import { createApp } from './app.mjs';

async function main() {
assert.match(process.env.STRIPE_SECRET_KEY ?? '', /^(sk_test_|rk_test_|rkcs_test_)/, 'Use a Stripe test secret key.');
assert.match(process.env.STRIPE_PUBLISHABLE_KEY ?? '', /^pk_test_/, 'Use the matching test publishable key.');
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY, { maxNetworkRetries: 2, timeout: 20_000 });
// Check permission before creating charges or accounts.
await stripe.accounts.list({ limit: 1 });
mkdirSync(new URL('./data', import.meta.url), { recursive: true });
const store = new JobStore(fileURLToPath(new URL('./data/connect-smoke.sqlite', import.meta.url)));
const payments = new Payments({ store, stripe, publishableKey: process.env.STRIPE_PUBLISHABLE_KEY });
const workers = new Workers({ store, stripe, publicURL: 'http://localhost:4242' });
const settlements = new Settlements({ store, stripe, workers });
const adminToken = randomUUID();
const app = createApp({ payments, stripe, workers, settlements, adminToken });
const server = app.listen(0, '127.0.0.1');
await new Promise(resolve => server.once('listening', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
const request = async (path, method = 'GET', body, token = adminToken) => {
  const response = await fetch(`${base}/${path}`, { method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: body ? JSON.stringify(body) : undefined });
  const value = await response.json();
  assert.equal(response.status, 200, value.error ?? 'Backend request failed.');
  return value;
};
try {
  await settlements.recover(); // Resume a prior interrupted test using its persisted operation.
  const session = await request('workers/session', 'POST');
  // A dedicated Custom account lets the automated test use fake identity data.
  // The iOS app uses the Express hosted onboarding flow in Workers.connect.
  let account = await stripe.accounts.create({ type: 'custom', country: 'US', business_type: 'individual',
    capabilities: { transfers: { requested: true } },
    metadata: { worker_id: session.worker.id, bounty_smoke_test: 'true' },
    business_profile: { mcc: '5734', url: 'https://accessible.stripe.com', product_description: 'Test design work' },
    individual: { first_name: 'Test', last_name: 'Worker', email: 'bounty-test@example.com', phone: '0000000000',
      dob: { day: 1, month: 1, year: 1902 }, id_number: '222222222',
      address: { line1: 'address_full_match', city: 'Ann Arbor', state: 'MI', postal_code: '48104', country: 'US' } },
    external_account: 'btok_us_verified',
    tos_acceptance: { date: Math.floor(Date.now() / 1000), ip: '127.0.0.1' },
  }, { idempotencyKey: `bounty-test-worker-${session.worker.id}` });
  for (let attempt = 0; account.capabilities?.transfers !== 'active' && attempt < 30; attempt++) {
    await delay(1000); account = await stripe.accounts.retrieve(account.id);
  }
  assert.equal(account.capabilities?.transfers, 'active', `Test account needs setup: ${account.requirements?.currently_due?.join(', ')}`);
  workers.save({ ...workers.get(session.worker.id), connectAccountID: account.id });
  const fund = async title => {
    const id = randomUUID();
    const sheet = await request('payment-sheet', 'POST', { id, title, details: 'Real Stripe sandbox settlement check.',
      category: 'Technology', isRemote: true, deadline: new Date(Date.now() + 86_400_000).toISOString(), amountCents: 1500 });
    const intentID = sheet.paymentIntentClientSecret.split('_secret_')[0];
    // A mismatched publishable key breaks PaymentSheet even if backend calls work.
    const visible = await new Stripe(process.env.STRIPE_PUBLISHABLE_KEY).paymentIntents.retrieve(intentID,
      { client_secret: sheet.paymentIntentClientSecret });
    assert.equal(visible.id, intentID, 'Publishable key must belong to the same sandbox.');
    await stripe.paymentIntents.confirm(intentID, { payment_method: 'pm_card_visa' });
    const job = await request(`jobs/${id}`); assert.equal(job.status, 'funded');
    return id;
  };
  const paid = await fund('Connect transfer smoke test');
  await request(`admin/jobs/${paid}/assign`, 'POST', { workerID: session.worker.id });
  await request(`admin/jobs/${paid}/review`, 'POST');
  const outcomes = await Promise.all([request(`admin/jobs/${paid}/approve`, 'POST'), request(`admin/jobs/${paid}/approve`, 'POST')]);
  assert.equal(outcomes[0].status, 'released'); assert.equal(outcomes[0].settlementReference, outcomes[1].settlementReference);
  const transfer = await stripe.transfers.retrieve(outcomes[0].settlementReference);
  assert.equal(transfer.amount, 1500); assert.equal(transfer.destination, account.id); assert.equal(transfer.livemode, false);
  const matches = await stripe.transfers.list({ transfer_group: `job_${paid}`, limit: 100 });
  assert.equal(matches.data.length, 1);
  assert.equal((await request(`admin/jobs/${paid}/audit`)).consistent, true);
  assert.equal((await request('workers/me/earnings', 'GET', undefined, session.token)).totals.usd.releasedCents, 1500);
  const refundable = await fund('Full refund smoke test');
  const refund = await request(`admin/jobs/${refundable}/refund`, 'POST');
  assert.equal(refund.status, 'refunded');
  assert.equal((await request(`admin/jobs/${refundable}/refund`, 'POST')).settlementReference, refund.settlementReference);
  const actualRefund = await stripe.refunds.retrieve(refund.settlementReference);
  assert.equal(actualRefund.amount, 1650); assert.equal(actualRefund.status, 'succeeded');
  assert.equal((await request(`admin/jobs/${refundable}/audit`)).consistent, true);
  console.log(JSON.stringify({ passed: true, workerAccount: account.id, paidJob: paid, transfer: transfer.id,
    refundedJob: refundable, refund: actualRefund.id, workerCents: 1500, refundedCents: 1650 }));
} finally {
  await new Promise(resolve => server.close(resolve));
  store.close();
}
}
main().catch(error => {
  const safe = String(error.message).replace(/(?:sk_test_|rk_test_|rkcs_test_|pk_test_|whsec_)[A-Za-z0-9_]+/g, '[redacted]')
    .replace(/pi_[A-Za-z0-9]+_secret_[A-Za-z0-9]+/g, '[redacted]');
  console.error(`Connect smoke test failed: ${safe}`);
  process.exitCode = 1;
});
