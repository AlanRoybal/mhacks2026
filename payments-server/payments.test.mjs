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
    { deadline: new Date(0).toISOString() }, { isRemote: 'yes' }, { category: ' ' },
    { category: 'x'.repeat(41) }, { category: 42 }]) {
    await assert.rejects(payments.prepare(draft(changes)), { status: 400 });
  }
  await assert.rejects(payments.prepare(null), { status: 400 });
  assert.equal(calls.length, 0);
});

test('custom category names survive checkout and storage', async t => {
  const { payments, store } = fixture(t);
  const input = draft({ category: '  Pet care  ' });
  const result = await payments.prepare(input);
  assert.equal(result.job.category, 'Pet care');
  assert.equal(store.get(input.id).category, 'Pet care');
  assert.equal(store.get(input.id).draft.category, 'Pet care');
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
  assert.equal(store.ledgerEvents(input.id).length, 1);
  assert.equal(store.ledgerEvents(input.id)[0].source, 'reconciliation');
  payments.applyIntent({ ...intent, status: 'requires_payment_method' });
  assert.equal(store.get(input.id).status, 'funded');
  assert.equal(store.ledgerEvents(input.id).length, 1);
});

test('funding and its append-only ledger survive a backend restart', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'bounty-payments-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const path = join(directory, 'jobs.sqlite');
  const original = new JobStore(path);
  const input = draft();
  const feeCents = Math.round(input.amountCents * 0.10);
  const saved = original.save({ ...input, feeCents, totalCents: input.amountCents + feeCents,
    currency: 'usd', status: 'draft', paymentIntentID: 'pi_restart' });
  const intent = { id: saved.paymentIntentID, metadata: { job_id: input.id }, status: 'succeeded',
    livemode: false, currency: saved.currency, amount: saved.totalCents, amount_received: saved.totalCents };
  const payments = new Payments({ store: original });
  payments.applyIntent(intent, { source: 'webhook', stripeEventID: 'evt_restart' });
  original.close();
  const reopened = new JobStore(path);
  try {
    const restarted = new Payments({ store: reopened });
    restarted.applyIntent(intent, { source: 'webhook', stripeEventID: 'evt_restart' });
    assert.equal(reopened.get(input.id).status, 'funded');
    const events = reopened.ledgerEvents(input.id);
    assert.equal(events.length, 1);
    assert.equal(events[0].stripeEventID, 'evt_restart');
    assert.throws(() => reopened.db.prepare('DELETE FROM LedgerEvents WHERE job_id = ?').run(input.id), /append-only/);
    assert.throws(() => reopened.db.prepare("UPDATE LedgerEvents SET type = 'OTHER' WHERE job_id = ?").run(input.id), /append-only/);
  } finally { reopened.close(); }
});

test('a failed database update rolls back funding and the ledger together', async t => {
  const { payments, store, intents } = fixture(t);
  const input = draft({ amountCents: 1500 });
  await payments.prepare(input);
  const intent = intents.get(store.get(input.id).paymentIntentID);
  intent.status = 'succeeded'; intent.amount_received = intent.amount;
  const save = store.save;
  store.save = () => { throw new Error('Simulated database write failure'); };
  assert.throws(() => payments.applyIntent(intent, { source: 'webhook', stripeEventID: 'evt_atomic' }), /write failure/);
  assert.equal(store.get(input.id).status, 'draft');
  assert.deepEqual(store.ledgerEvents(input.id), []);
  store.save = save;
  payments.applyIntent(intent, { source: 'webhook', stripeEventID: 'evt_atomic' });
  assert.equal(store.get(input.id).status, 'funded');
  assert.equal(store.ledgerEvents(input.id).length, 1);
});

test('a checkout retry cannot overwrite funding delivered during a Stripe request', async t => {
  const { payments, stripe, store, intents } = fixture(t);
  const input = draft();
  await payments.prepare(input);
  const intent = intents.get(store.get(input.id).paymentIntentID);
  const stale = { ...intent };
  let release;
  stripe.paymentIntents.retrieve = () => new Promise(resolve => { release = () => resolve(stale); });
  const retry = payments.prepare(input);
  payments.applyIntent({ ...intent, status: 'succeeded', amount_received: intent.amount },
    { source: 'webhook', stripeEventID: 'evt_race' });
  release();
  assert.equal((await retry).job.status, 'funded');
  assert.equal(store.get(input.id).status, 'funded');
  assert.equal(store.ledgerEvents(input.id).length, 1);
});

test('created, failed, canceled, processing, and authorization-only payments stay unfunded', async t => {
  const { payments, store, intents } = fixture(t);
  const input = draft({ amountCents: 1500 });
  const prepared = await payments.prepare(input);
  assert.equal(prepared.job.totalCents, 1650);
  const intent = intents.get(store.get(input.id).paymentIntentID);
  for (const status of ['requires_payment_method', 'requires_action', 'requires_capture', 'processing', 'canceled']) {
    payments.applyIntent({ ...intent, status });
    assert.equal(store.get(input.id).status, 'draft');
    assert.deepEqual(store.ledgerEvents(input.id), []);
  }
  intent.status = 'canceled';
  await assert.rejects(payments.prepare(input), { status: 409 });
});

test('duplicate success cannot rewind a later job state', async t => {
  const { payments, store, intents } = fixture(t);
  const input = draft();
  await payments.prepare(input);
  const intent = intents.get(store.get(input.id).paymentIntentID);
  intent.status = 'succeeded'; intent.amount_received = intent.amount;
  payments.applyIntent(intent);
  store.save({ ...store.get(input.id), status: 'in_review' });
  payments.applyIntent(intent, { source: 'webhook', stripeEventID: 'evt_late' });
  assert.equal(store.get(input.id).status, 'in_review');
  assert.equal(store.ledgerEvents(input.id).length, 1);
});

test('webhook rejects forgery and accepts signed, duplicate success events', async t => {
  const { payments, stripe, store, intents } = fixture(t);
  const secret = 'whsec_test_secret';
  const app = createApp({ payments, stripe, webhookSecret: secret });
  const server = app.listen(0, '127.0.0.1');
  await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  const input = draft({ amountCents: 1500 });
  const prepared = await fetch(`${base}/payment-sheet`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(input),
  });
  assert.equal(prepared.status, 200);
  const intent = intents.get(store.get(input.id).paymentIntentID);
  const other = draft();
  await payments.prepare(other);
  const deliver = async (type, object, id = `evt_${randomUUID()}`) => {
    const payload = JSON.stringify({ id, type, data: { object } });
    return fetch(`${base}/stripe/webhook`, { method: 'POST', headers: {
      'Content-Type': 'application/json',
      'Stripe-Signature': stripe.webhooks.generateTestHeaderString({ payload, secret }),
    }, body: payload });
  };
  for (const [type, status] of [['payment_intent.payment_failed', 'requires_payment_method'],
    ['payment_intent.processing', 'processing'], ['payment_intent.canceled', 'canceled']]) {
    assert.equal((await deliver(type, { ...intent, status })).status, 200);
    assert.equal(store.get(input.id).status, 'draft');
    assert.deepEqual(store.ledgerEvents(input.id), []);
  }
  intent.status = 'succeeded'; intent.amount_received = intent.amount;
  const body = JSON.stringify({ id: 'evt_test', type: 'payment_intent.succeeded', data: { object: intent } });
  const forged = await fetch(`${base}/stripe/webhook`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'Stripe-Signature': 'fake' }, body,
  });
  assert.equal(forged.status, 400);
  assert.equal(store.get(input.id).status, 'draft');
  assert.deepEqual(store.ledgerEvents(input.id), []);
  for (const changes of [{ amount: 1 }, { currency: 'eur' }, { amount_received: 1 }, { livemode: true }]) {
    assert.equal((await deliver('payment_intent.succeeded', { ...intent, ...changes })).status, 409);
    assert.equal(store.get(input.id).status, 'draft');
    assert.deepEqual(store.ledgerEvents(input.id), []);
  }
  assert.equal((await deliver('payment_intent.succeeded', { ...intent, metadata: { job_id: other.id } })).status, 200);
  assert.equal(store.get(other.id).status, 'draft');
  const signature = stripe.webhooks.generateTestHeaderString({ payload: body, secret });
  for (let i = 0; i < 2; i++) {
    const accepted = await fetch(`${base}/stripe/webhook`, {
      method: 'POST', headers: { 'Content-Type': 'application/json', 'Stripe-Signature': signature }, body,
    });
    assert.equal(accepted.status, 200);
  }
  assert.equal(store.get(input.id).status, 'funded');
  const events = store.ledgerEvents(input.id);
  assert.equal(events.length, 1);
  assert.equal(events[0].type, 'JOB_FUNDED');
  assert.equal(events[0].jobID, input.id);
  assert.equal(events[0].paymentIntentID, intent.id);
  assert.equal(events[0].stripeEventID, 'evt_test');
  assert.equal(events[0].source, 'webhook');
  assert.equal(events[0].totalCents, 1650);
  assert.equal((await deliver('payment_intent.succeeded', intent)).status, 200);
  assert.equal((await deliver('payment_intent.payment_failed', { ...intent, status: 'requires_payment_method' })).status, 200);
  assert.equal(store.get(input.id).status, 'funded');
  assert.equal(store.ledgerEvents(input.id).length, 1);
  assert.equal(store.get(other.id).status, 'draft');
  assert.deepEqual(store.ledgerEvents(other.id), []);
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
