import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import Stripe from 'stripe';
import { JobStore, Payments } from './payments.mjs';
import { createApp } from './app.mjs';

const draft = (changes = {}) => ({ id: randomUUID(), title: 'Mow the lawn', details: 'Mow the front lawn and clear the clippings.',
  category: 'Home', isRemote: false, deadline: new Date(Date.now() + 86_400_000).toISOString(), amountCents: 2500, ...changes });

function fixture(t, store = new JobStore()) {
  const intents = new Map();
  const calls = [];
  const stripe = new Stripe('sk_test_example');
  stripe.paymentIntents = {
    create: async (params, options) => {
      calls.push({ params, options });
      const intent = { ...params, id: `pi_${randomUUID()}`, client_secret: 'pi_test_secret_test',
        status: 'requires_payment_method', amount_received: 0, livemode: false };
      intents.set(intent.id, intent);
      return intent;
    },
    retrieve: async id => intents.get(id),
  };
  const payments = new Payments({ stripe, store, publishableKey: 'pk_test_example' });
  t.after(() => store.close());
  return { payments, stripe, store, intents, calls };
}

test('charges the saved job pay plus 10% fee, ignoring client totals', async t => {
  const { payments, calls } = fixture(t);
  const result = await payments.prepare(draft({ amountCents: 2505, totalCents: 1, feeCents: 0 }));
  assert.equal(calls[0].params.amount, 2756);
  assert.equal(result.job.feeCents, 251);
  assert.equal(result.job.status, 'draft');
  assert.equal('paymentIntentID' in result.job, false);
  assert.equal(calls[0].params.currency, 'usd');
  assert.deepEqual(calls[0].params.allowed_payment_method_types, ['card']);
});

test('concurrent and sequential retries reuse the same PaymentIntent', async t => {
  const { payments, calls } = fixture(t);
  const input = draft();
  const results = await Promise.all([payments.prepare(input), payments.prepare(input)]);
  await payments.prepare(input);
  assert.equal(calls.length, 1);
  assert.equal(results[0].paymentIntentClientSecret, results[1].paymentIntentClientSecret);
  assert.equal(calls[0].options.idempotencyKey, `bounty-funding-${input.id}`);
  await assert.rejects(payments.prepare({ ...input, amountCents: 100 }), { status: 409 });
});

test('invalid prices, job IDs, deadlines, and payloads never reach Stripe', async t => {
  const { payments, calls } = fixture(t);
  for (const amountCents of [0, -1, 49, 1.5, '2500', 1_000_001, NaN]) {
    await assert.rejects(payments.prepare(draft({ amountCents })), { status: 400 });
  }
  for (const changes of [{ id: '../../secret' }, { title: '' }, { details: ' ' }, { deadline: 'yesterday' },
    { deadline: new Date(0).toISOString() }, { isRemote: 'yes' }, { category: 'Unknown' }]) {
    await assert.rejects(payments.prepare(draft(changes)), { status: 400 });
  }
  await assert.rejects(payments.prepare(null), { status: 400 });
  assert.equal(calls.length, 0);
});

test('only a matching, fully received succeeded charge funds a job', async t => {
  const { payments, store, intents } = fixture(t);
  const input = draft();
  await payments.prepare(input);
  const saved = store.get(input.id);
  const intent = intents.get(saved.paymentIntentID);
  intent.status = 'processing';
  assert.equal((await payments.status(input.id)).status, 'draft');
  intent.status = 'succeeded';
  await assert.rejects(payments.status(input.id), { status: 409 });
  intent.amount_received = saved.totalCents;
  assert.throws(() => payments.applyIntent({ ...intent, amount: 1 }), { status: 409 });
  assert.throws(() => payments.applyIntent({ ...intent, currency: 'eur' }), { status: 409 });
  assert.throws(() => payments.applyIntent({ ...intent, livemode: true }), { status: 409 });
  assert.equal(payments.applyIntent({ ...intent, id: 'pi_unrelated' }), null);
  assert.equal(payments.applyIntent({ ...intent, metadata: {} }), null);
  assert.equal((await payments.status(input.id)).status, 'funded');
  payments.applyIntent({ ...intent, status: 'requires_payment_method' });
  assert.equal(store.get(input.id).status, 'funded');
});

test('job ledger survives a backend restart', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'bounty-payments-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const path = join(directory, 'jobs.sqlite');
  const original = new JobStore(path);
  const input = draft();
  original.save({ ...input, status: 'funded' });
  original.close();
  const reopened = new JobStore(path);
  assert.equal(reopened.get(input.id).status, 'funded');
  reopened.close();
});

test('webhook rejects forgery and accepts signed, duplicate success events', async t => {
  const { payments, stripe, store, intents } = fixture(t);
  const secret = 'whsec_test_secret';
  const app = createApp({ payments, stripe, webhookSecret: secret });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const input = draft();
  const prepared = await fetch(`${base}/payment-sheet`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  });
  assert.equal(prepared.status, 200);
  const intent = intents.get(store.get(input.id).paymentIntentID);
  intent.status = 'succeeded'; intent.amount_received = intent.amount;
  const body = JSON.stringify({ id: 'evt_test', type: 'payment_intent.succeeded', data: { object: intent } });
  const forged = await fetch(`${base}/stripe/webhook`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Stripe-Signature': 'fake' }, body,
  });
  assert.equal(forged.status, 400);
  assert.equal(store.get(input.id).status, 'draft');
  const signature = stripe.webhooks.generateTestHeaderString({ payload: body, secret });
  for (let i = 0; i < 2; i++) {
    const accepted = await fetch(`${base}/stripe/webhook`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Stripe-Signature': signature }, body,
    });
    assert.equal(accepted.status, 200);
  }
  assert.equal(store.get(input.id).status, 'funded');
  const unrelatedBody = JSON.stringify({ id: 'evt_other', type: 'payment_intent.succeeded', data: { object: { ...intent, metadata: {} } } });
  const unrelatedSignature = stripe.webhooks.generateTestHeaderString({ payload: unrelatedBody, secret });
  const unrelated = await fetch(`${base}/stripe/webhook`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Stripe-Signature': unrelatedSignature }, body: unrelatedBody,
  });
  assert.equal(unrelated.status, 200);
  const malformed = await fetch(`${base}/payment-sheet`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: '{',
  });
  assert.equal(malformed.status, 400);
  assert.equal((await fetch(`${base}/jobs/${randomUUID()}`)).status, 404);
});
