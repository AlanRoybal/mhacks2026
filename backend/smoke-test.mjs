// Creates and confirms a test charge. Run against the local test backend only.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import Stripe from 'stripe';

assert.match(process.env.STRIPE_SECRET_KEY ?? '', /^(sk_test_|rk_test_|rkcs_test_)/);
const verifyWebhook = process.argv.includes('--webhook');
if (verifyWebhook) {
  assert.match(process.env.STRIPE_WEBHOOK_SECRET ?? '', /^whsec_/, 'Configure the Stripe CLI listener signing secret in .env.');
}
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const base = 'http://127.0.0.1:4242';
const input = { id: randomUUID(), title: 'Stripe sandbox smoke test', details: 'Test job funding with a Stripe test card.',
  category: 'Technology', isRemote: true, deadline: new Date(Date.now() + 86_400_000).toISOString(), amountCents: 1500 };
const prepare = async (draft = input) => {
  const response = await fetch(`${base}/payment-sheet`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(draft),
  });
  assert.equal(response.status, 200);
  return response.json();
};
const initial = await prepare();
assert.equal(initial.job.totalCents, 1650);
assert.equal(initial.job.status, 'draft');
assert.equal((await prepare()).paymentIntentClientSecret, initial.paymentIntentClientSecret);
const intentID = initial.paymentIntentClientSecret.split('_secret_')[0];
const canceledDraft = { ...input, id: randomUUID(), title: 'Canceled sandbox checkout' };
const canceledSheet = await prepare(canceledDraft);
const canceledID = canceledSheet.paymentIntentClientSecret.split('_secret_')[0];
await stripe.paymentIntents.cancel(canceledID);
assert.equal((await (await fetch(`${base}/jobs/${canceledDraft.id}`)).json()).status, 'draft');
try {
  await stripe.paymentIntents.confirm(intentID, { payment_method: 'pm_card_chargeDeclined' });
  assert.fail('The decline test card unexpectedly succeeded.');
} catch (error) { assert.equal(error.code, 'card_declined'); }
assert.equal((await (await fetch(`${base}/jobs/${input.id}`)).json()).status, 'draft');
const intent = await stripe.paymentIntents.confirm(intentID, { payment_method: 'pm_card_visa' });
assert.equal(intent.status, 'succeeded');
assert.equal(intent.livemode, false);
if (verifyWebhook) {
  // GET /jobs/:id can reconcile with Stripe itself. Read the ledger first to
  // prove the webhook funded this job without that fallback doing the work.
  const ledger = new DatabaseSync(fileURLToPath(new URL('./data/jobs.sqlite', import.meta.url)), { readOnly: true });
  try {
    const read = ledger.prepare('SELECT record FROM jobs WHERE id = ?');
    const funding = ledger.prepare('SELECT record FROM LedgerEvents WHERE job_id = ?');
    const timeout = Date.now() + 30_000;
    let status;
    do {
      status = JSON.parse(read.get(input.id).record).status;
      if (status === 'funded') break;
      await delay(250);
    } while (Date.now() < timeout);
    assert.equal(status, 'funded', 'No funding webhook arrived. Run npm run webhooks, copy its signing secret to .env, and restart the backend.');
    const events = funding.all(input.id).map(row => JSON.parse(row.record));
    assert.equal(events.length, 1, 'Funding must write exactly one ledger event.');
    assert.equal(events[0].type, 'JOB_FUNDED');
    assert.equal(events[0].source, 'webhook', 'The webhook must perform funding before any success reconciliation.');
    assert.equal(events[0].paymentIntentID, intentID);
    assert.equal(events[0].totalCents, 1650);
    assert.match(events[0].stripeEventID, /^evt_/);
    assert.equal(JSON.parse(read.get(canceledDraft.id).record).status, 'draft');
    assert.equal(funding.all(canceledDraft.id).length, 0);
  } finally { ledger.close(); }
  console.log('Webhook check passed: Stripe delivery atomically funded the job and wrote one LedgerEvents entry before any success-status request.');
}
const funded = await (await fetch(`${base}/jobs/${input.id}`)).json();
assert.equal(funded.status, 'funded');
assert.equal(funded.totalCents, 1650);
console.log(`Sandbox check passed: canceled checkout and declined card stayed unfunded; Visa funded job ${input.id} for $16.50 ($15 pay + $1.50 fee).`);
