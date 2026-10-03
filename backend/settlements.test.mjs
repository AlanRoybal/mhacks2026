import test from 'node:test';
import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { privateKeyToAccount, generatePrivateKey } from 'viem/accounts';
import Stripe from 'stripe';
import { JobStore, Payments } from './payments.mjs';
import { Workers } from './workers.mjs';
import { Settlements } from './settlements.mjs';
import { createApp } from './app.mjs';

function fixture(t) {
  const store = new JobStore(); t.after(() => store.close());
  const stripe = new Stripe('sk_test_example');
  const transfers = new Map(), refunds = new Map(), intents = new Map(), accounts = new Map(), keys = new Map();
  const calls = [];
  let fail = false, loseResponse = false;
  stripe.paymentIntents = { retrieve: async id => intents.get(id) };
  stripe.accounts = { retrieve: async id => accounts.get(id) };
  for (const [name, records, prefix] of [['transfers', transfers, 'tr'], ['refunds', refunds, 're']]) {
    stripe[name] = {
      create: async (params, options) => {
        calls.push({ name, params, key: options.idempotencyKey });
        if (fail) throw new Error('temporary outage');
        const result = keys.get(options.idempotencyKey) ?? { ...params, id: `${prefix}_${randomUUID()}`, livemode: false,
          currency: 'usd', status: 'succeeded', amount_reversed: 0, reversed: false };
        if (name === 'refunds') delete result.livemode; // Matches the actual Stripe Refund schema.
        records.set(result.id, result); keys.set(options.idempotencyKey, result);
        if (loseResponse) { loseResponse = false; throw new Error('response lost after Stripe accepted'); }
        return result;
      },
      retrieve: async id => records.get(id),
      list: async () => ({ data: [...records.values()] }),
    };
  }
  const workers = new Workers({ store, stripe });
  const session = workers.create();
  const accountID = `acct_${randomUUID()}`;
  accounts.set(accountID, { id: accountID, metadata: { worker_id: session.worker.id }, capabilities: { transfers: 'active' } });
  workers.save({ ...session.worker, connectAccountID: accountID });
  let now = Date.now();
  const settlements = new Settlements({ store, stripe, workers, clock: () => now });
  const makeJob = () => {
    const job = { id: randomUUID(), title: 'Logo', amountCents: 1500, feeCents: 150, totalCents: 1650, currency: 'usd',
      fundingRail: 'stripe', status: 'draft', paymentIntentID: `pi_${randomUUID()}`, deadline: new Date(now + 60_000).toISOString() };
    store.save(job);
    const intent = { id: job.paymentIntentID, livemode: false, status: 'succeeded', amount: job.totalCents,
      amount_received: job.totalCents, currency: 'usd', metadata: { job_id: job.id }, latest_charge: `ch_${randomUUID()}` };
    intents.set(intent.id, intent);
    new Payments({ store, stripe }).applyIntent(intent);
    return store.get(job.id);
  };
  return { store, stripe, workers, settlements, session, makeJob, calls, transfers, refunds, accounts,
    fail: value => { fail = value; }, lose: () => { loseResponse = true; }, advance: ms => { now += ms; } };
}
async function reviewed(f) {
  const job = f.makeJob();
  await f.settlements.assign(job.id, f.session.worker.id);
  f.settlements.review(job.id);
  return job;
}

test('approval transfers only job pay to the assigned Connect account once', async t => {
  const f = fixture(t), job = await reviewed(f);
  const results = await Promise.all([f.settlements.settle(job.id, 'release'), f.settlements.settle(job.id, 'release')]);
  assert.equal(results[0].status, 'released'); assert.equal(results[1].status, 'released');
  assert.equal(f.transfers.size, 1);
  assert.equal(f.calls[0].params.amount, 1500);
  assert.equal(f.calls[0].params.destination, f.workers.get(f.session.worker.id).connectAccountID);
  assert.match(f.calls[0].params.source_transaction, /^ch_/);
  await f.settlements.settle(job.id, 'release');
  assert.equal(f.transfers.size, 1);
  assert.equal(f.store.ledgerEvents(job.id).filter(event => event.type === 'JOB_RELEASED').length, 1);
  assert.equal(f.settlements.earnings(f.session.worker.id).totals.usd.releasedCents, 1500);
  assert.equal((await f.settlements.audit(job.id)).consistent, true);
  await assert.rejects(f.settlements.settle(job.id, 'refund'), { status: 409 });
});
test('failed transfer remains pending and a safe retry pays once', async t => {
  const f = fixture(t), job = await reviewed(f);
  f.fail(true); await assert.rejects(f.settlements.settle(job.id, 'release'));
  assert.equal(f.store.get(job.id).status, 'release_pending');
  assert.equal(f.settlements.earnings(f.session.worker.id).totals.usd.releasedCents, 0);
  assert.equal(f.settlements.earnings(f.session.worker.id).totals.usd.pendingCents, 1500);
  f.fail(false); await f.settlements.settle(job.id, 'release');
  assert.equal(f.calls[0].key, f.calls[1].key); assert.equal(f.transfers.size, 1);
});
test('lost Stripe response recovers without double transfer', async t => {
  const f = fixture(t), job = await reviewed(f);
  f.lose(); await assert.rejects(f.settlements.settle(job.id, 'release'));
  assert.equal(f.transfers.size, 1);
  const restarted = new Settlements({ store: f.store, stripe: f.stripe, workers: f.workers });
  await restarted.settle(job.id, 'release');
  assert.equal(f.transfers.size, 1); assert.equal(f.calls[0].key, f.calls[1].key);
});
test('database failure after a transfer recovers exactly once', async t => {
  const f = fixture(t), job = await reviewed(f);
  const append = f.store.appendLedger.bind(f.store);
  f.store.appendLedger = (record, type, details) => { if (type === 'JOB_RELEASED') throw new Error('disk unavailable'); return append(record, type, details); };
  await assert.rejects(f.settlements.settle(job.id, 'release'));
  assert.equal(f.transfers.size, 1); assert.equal(f.store.get(job.id).status, 'release_pending');
  assert.equal(f.store.ledgerEvents(job.id).filter(event => event.type === 'JOB_RELEASED').length, 0);
  f.store.appendLedger = append; await f.settlements.settle(job.id, 'release');
  assert.equal(f.transfers.size, 1); assert.equal(f.store.get(job.id).status, 'released');
});
test('refund returns the entire charge once and prevents release', async t => {
  const f = fixture(t), job = f.makeJob();
  await f.settlements.settle(job.id, 'refund');
  await f.settlements.settle(job.id, 'refund');
  assert.equal(f.refunds.size, 1); assert.equal(f.calls[0].params.amount, 1650);
  assert.equal(f.store.get(job.id).status, 'refunded');
  await assert.rejects(f.settlements.settle(job.id, 'release'), { status: 409 });
  assert.equal((await f.settlements.audit(job.id)).consistent, true);
});
test('approval and refund requests cannot reserve conflicting operations', async t => {
  const f = fixture(t), job = await reviewed(f);
  f.advance(70_000);
  const outcomes = await Promise.allSettled([f.settlements.settle(job.id, 'release'), f.settlements.settle(job.id, 'refund')]);
  assert.equal(outcomes.filter(result => result.status === 'fulfilled').length, 1);
  assert.equal(f.transfers.size + f.refunds.size, 1);
});
test('deadline scheduler refunds unfinished work and review timer releases approved work', async t => {
  const f = fixture(t), unfinished = f.makeJob(), approved = await reviewed(f);
  await f.settlements.assign(unfinished.id, f.session.worker.id);
  await assert.rejects(f.settlements.settle(unfinished.id, 'refund'), { status: 409 });
  f.advance(121_000); await f.settlements.recover();
  assert.equal(f.store.get(unfinished.id).status, 'refunded');
  assert.equal(f.store.get(approved.id).status, 'released');
});
test('expired idempotency window requires reconciliation and never blindly pays again', async t => {
  const f = fixture(t), job = await reviewed(f);
  f.lose(); await assert.rejects(f.settlements.settle(job.id, 'release'));
  f.advance(24 * 60 * 60 * 1000);
  await f.settlements.settle(job.id, 'release'); assert.equal(f.transfers.size, 1); assert.equal(f.calls.length, 1);
  const second = await reviewed(f); f.fail(true); await assert.rejects(f.settlements.settle(second.id, 'release'));
  f.fail(false); f.advance(24 * 60 * 60 * 1000);
  await assert.rejects(f.settlements.settle(second.id, 'release'), { status: 409 });
  assert.equal(f.transfers.size, 1);
});
test('worker wallet binding requires a one-time valid signature', async t => {
  const f = fixture(t), signer = privateKeyToAccount(generatePrivateKey());
  const challenge = f.workers.challenge(f.session.worker, signer.address);
  await assert.rejects(f.workers.verifyWallet(f.workers.get(f.session.worker.id), '0x00'), { status: 401 });
  const signature = await signer.signMessage({ message: challenge.message });
  const verified = await f.workers.verifyWallet(f.workers.get(f.session.worker.id), signature);
  assert.equal(verified.walletAddress, signer.address);
  await assert.rejects(f.workers.verifyWallet(f.workers.get(f.session.worker.id), signature), { status: 400 });
  assert.throws(() => f.workers.authenticate('wrong'), { status: 401 });
});
test('wrong worker or inactive Connect capability cannot receive a job', async t => {
  const f = fixture(t), job = f.makeJob();
  const worker = f.workers.get(f.session.worker.id);
  f.accounts.get(worker.connectAccountID).metadata.worker_id = randomUUID();
  await assert.rejects(f.settlements.assign(job.id, worker.id), { status: 409 });
  assert.equal(f.store.get(job.id).status, 'funded'); assert.equal(f.transfers.size, 0);
});
test('decision endpoints require the admin token; worker earnings require their session', async t => {
  const f = fixture(t), job = await reviewed(f);
  const app = createApp({ payments: new Payments({ store: f.store, stripe: f.stripe }), stripe: f.stripe,
    workers: f.workers, settlements: f.settlements, adminToken: 'test-admin' });
  const server = app.listen(0, '127.0.0.1'); await new Promise(resolve => server.once('listening', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const base = `http://127.0.0.1:${server.address().port}`;
  assert.equal((await fetch(`${base}/admin/jobs/${job.id}/approve`, { method: 'POST' })).status, 401);
  assert.equal(f.transfers.size, 0);
  assert.equal((await fetch(`${base}/workers/me/earnings`)).status, 401);
  const released = await fetch(`${base}/admin/jobs/${job.id}/approve`, { method: 'POST', headers: { Authorization: 'Bearer test-admin' } });
  assert.equal(released.status, 200);
  const earnings = await (await fetch(`${base}/workers/me/earnings`, { headers: { Authorization: `Bearer ${f.session.token}` } })).json();
  assert.equal(earnings.totals.usd.releasedCents, 1500);
  const jobs = await (await fetch(`${base}/workers/me/jobs`, { headers: { Authorization: `Bearer ${f.session.token}` } })).json();
  assert.equal(jobs[0].id, job.id);
  const other = f.workers.create();
  assert.deepEqual(await (await fetch(`${base}/workers/me/jobs`, { headers: { Authorization: `Bearer ${other.token}` } })).json(), []);
});
test('a pending refund cannot be recorded as refunded until Stripe confirms it', async t => {
  const f = fixture(t), job = f.makeJob();
  const create = f.stripe.refunds.create;
  f.stripe.refunds.create = async (...args) => { const refund = await create(...args); refund.status = 'pending'; return refund; };
  assert.equal((await f.settlements.settle(job.id, 'refund')).status, 'refund_pending');
  assert.equal(f.store.ledgerEvents(job.id).filter(event => event.type === 'JOB_REFUNDED').length, 0);
  [...f.refunds.values()][0].status = 'succeeded';
  assert.equal((await f.settlements.settle(job.id, 'refund')).status, 'refunded');
  assert.equal(f.calls.length, 1);
});
test('a transfer from another charge cannot complete a job', async t => {
  const f = fixture(t), job = await reviewed(f);
  const create = f.stripe.transfers.create;
  f.stripe.transfers.create = async (...args) => { const transfer = await create(...args); transfer.source_transaction = 'ch_wrong'; return transfer; };
  await assert.rejects(f.settlements.settle(job.id, 'release'), { status: 409 });
  assert.equal(f.store.get(job.id).status, 'release_pending');
  assert.equal(f.store.ledgerEvents(job.id).filter(event => event.type === 'JOB_RELEASED').length, 0);
});
test('ledger audits detect external reversals and earnings flag reconciliation', async t => {
  const f = fixture(t), job = await reviewed(f);
  const released = await f.settlements.settle(job.id, 'release');
  f.transfers.get(released.settlementReference).reversed = true;
  assert.equal((await f.settlements.audit(job.id)).consistent, false);
  const earnings = await f.settlements.verifiedEarnings(f.session.worker.id);
  assert.equal(earnings.totals.usd.releasedCents, 0);
  assert.equal(earnings.entries[0].status, 'settlement_issue');
  const other = f.workers.create();
  assert.equal((await f.settlements.verifiedEarnings(other.worker.id)).entries.length, 0);
});
