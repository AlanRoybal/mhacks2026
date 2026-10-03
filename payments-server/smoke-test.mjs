// Creates and confirms a test charge. Run against the local test backend only.
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import Stripe from 'stripe';

assert.match(process.env.STRIPE_SECRET_KEY ?? '', /^(sk_test_|rk_test_|rkcs_test_)/);
const stripe = new Stripe(process.env.STRIPE_SECRET_KEY);
const base = 'http://127.0.0.1:4242';
const input = { id: randomUUID(), title: 'Stripe sandbox smoke test', details: 'Test job funding with a Stripe test card.',
  category: 'Technology', isRemote: true, deadline: new Date(Date.now() + 86_400_000).toISOString(), amountCents: 2500 };
const prepare = async () => {
  const response = await fetch(`${base}/payment-sheet`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  });
  assert.equal(response.status, 200);
  return response.json();
};
const initial = await prepare();
assert.equal(initial.job.totalCents, 2750);
assert.equal(initial.job.status, 'draft');
assert.equal((await prepare()).paymentIntentClientSecret, initial.paymentIntentClientSecret);
const intentID = initial.paymentIntentClientSecret.split('_secret_')[0];
try {
  await stripe.paymentIntents.confirm(intentID, { payment_method: 'pm_card_chargeDeclined' });
  assert.fail('The decline test card unexpectedly succeeded.');
} catch (error) { assert.equal(error.code, 'card_declined'); }
assert.equal((await (await fetch(`${base}/jobs/${input.id}`)).json()).status, 'draft');
const intent = await stripe.paymentIntents.confirm(intentID, { payment_method: 'pm_card_visa' });
assert.equal(intent.status, 'succeeded');
assert.equal(intent.livemode, false);
const funded = await (await fetch(`${base}/jobs/${input.id}`)).json();
assert.equal(funded.status, 'funded');
assert.equal(funded.totalCents, 2750);
console.log(`Sandbox check passed: declined card stayed unfunded; Visa funded job ${input.id} for $27.50.`);
