import express from 'express';
import { PaymentError } from './payments.mjs';
import { timingSafeEqual } from 'node:crypto';

export function createApp({ payments, stripe, webhookSecret, workers, settlements, crypto, adminToken }) {
  const app = express();
  app.disable('x-powered-by');
  app.use((req, res, next) => { res.set('Cache-Control', 'no-store'); next(); });
  // Stripe signatures are checked against the original bytes, before JSON parsing.
  app.post('/stripe/webhook', express.raw({ type: 'application/json', limit: '64kb' }), async (req, res, next) => {
    if (!webhookSecret) return res.status(503).json({ error: 'Configure STRIPE_WEBHOOK_SECRET.' });
    let event;
    try { event = stripe.webhooks.constructEvent(req.body, req.get('stripe-signature'), webhookSecret); }
    catch { return res.status(400).json({ error: 'Invalid webhook signature.' }); }
    try {
      if (['payment_intent.succeeded', 'payment_intent.payment_failed', 'payment_intent.processing', 'payment_intent.canceled'].includes(event.type)) {
        payments.applyIntent(event.data.object, { source: 'webhook', stripeEventID: event.id });
      }
      res.json({ received: true });
    } catch (error) { next(error); }
  });
  app.use(express.json({ limit: '16kb' }));
  const handler = operation => async (req, res, next) => { try { res.json(await operation(req)); } catch (error) { next(error); } };
  const bearer = req => req.get('authorization')?.replace(/^Bearer /, '');
  const admin = (req, res, next) => {
    if (!adminToken) return res.status(503).json({ error: 'Configure BOUNTY_ADMIN_TOKEN.' });
    const supplied = Buffer.from(bearer(req) ?? '');
    const expected = Buffer.from(adminToken);
    if (supplied.length !== expected.length || !timingSafeEqual(supplied, expected)) return res.status(401).json({ error: 'Backend decision authorization required.' });
    if (!settlements) return res.status(503).json({ error: 'Settlement service unavailable.' });
    next();
  };
  const worker = (req, res, next) => {
    try {
      if (!workers) throw new PaymentError(503, 'Worker service unavailable.');
      req.worker = workers.authenticate(bearer(req));
      next();
    } catch (error) { next(error); }
  };
  const chain = (req, res, next) => {
    if (!crypto) return res.status(503).json({ error: 'Base Sepolia escrow is not deployed/configured yet.' });
    next();
  };
  app.post('/workers/session', handler(() => {
    if (!workers) throw new PaymentError(503, 'Worker service unavailable.');
    return workers.create();
  }));
  app.get('/workers/me', worker, handler(req => workers.publicWorker(req.worker)));
  app.post('/workers/me/connect', worker, handler(req => workers.connect(req.worker)));
  app.post('/workers/me/wallet/challenge', worker, handler(req => workers.challenge(req.worker, req.body?.address)));
  app.post('/workers/me/wallet/verify', worker, handler(req => workers.verifyWallet(req.worker, req.body?.signature)));
  app.get('/workers/me/earnings', worker, handler(req => settlements.verifiedEarnings(req.worker.id)));
  app.get('/workers/me/jobs', worker, handler(req => payments.store.list()
    .filter(job => job.workerID === req.worker.id).map(job => payments.publicJob(job))));
  app.get('/crypto/config', handler(() => ({ enabled: !!crypto, chainID: 84532, tokenAddress: crypto?.token ?? null, escrowAddress: crypto?.address ?? null })));
  app.post('/crypto/prepare', chain, handler(req => crypto.prepare(req.body)));
  app.post('/crypto/jobs/:id/confirm', chain, handler(req => crypto.confirm(req.params.id, req.body?.transactionHash)));
  app.get('/crypto/jobs/:id/refund-transaction', chain, handler(req => crypto.refundTransaction(req.params.id)));
  app.get('/crypto/receipts/:hash', chain, handler(async req => {
    if (!/^0x[0-9a-f]{64}$/i.test(req.params.hash)) throw new PaymentError(400, 'A transaction hash is required.');
    const receipt = await crypto.public.waitForTransactionReceipt({ hash: req.params.hash, confirmations: crypto.confirmations, timeout: 45_000 });
    return { status: receipt.status };
  }));
  app.get('/admin/jobs', admin, handler(() => settlements.store.list().map(job => payments.publicJob(job))));
  app.get('/admin/workers', admin, handler(() => workers.list()));
  app.post('/admin/jobs/:id/assign', admin, handler(async req => payments.publicJob(await settlements.assign(req.params.id, req.body?.workerID))));
  app.post('/admin/jobs/:id/review', admin, handler(req => payments.publicJob(settlements.review(req.params.id, req.body?.reviewSeconds ?? 120))));
  app.post('/admin/jobs/:id/approve', admin, handler(async req => payments.publicJob(await settlements.settle(req.params.id, 'release'))));
  app.post('/admin/jobs/:id/refund', admin, handler(async req => payments.publicJob(await settlements.settle(req.params.id, 'refund'))));
  app.get('/admin/jobs/:id/audit', admin, handler(req => settlements.audit(req.params.id)));
  app.get(['/connect/return', '/connect/refresh'], (req, res) => res.type('html').send('<!doctype html><meta name="viewport" content="width=device-width"><h1>Return to Bounty</h1><p>Open Earnings to check your payout setup. If the link expired, tap Set up payouts again.</p><a href="bounty://connect-return">Open Bounty</a>'));
  app.get('/health', (req, res) => res.json({ status: 'ok', mode: 'test' }));
  app.post('/payment-sheet', async (req, res, next) => {
    try { res.json(await payments.prepare(req.body)); } catch (error) { next(error); }
  });
  app.get('/jobs/:id', async (req, res, next) => {
    try {
      const job = payments.store.get(req.params.id.toLowerCase());
      if (job?.fundingRail === 'usdc') {
        if (!crypto) throw new PaymentError(503, 'Chain client unavailable.');
        res.json(await crypto.status(req.params.id));
      } else res.json(await payments.status(req.params.id));
    } catch (error) { next(error); }
  });
  app.use((req, res) => res.status(404).json({ error: 'Endpoint not found.' }));
  app.use((error, req, res, next) => {
    if (error instanceof PaymentError) return res.status(error.status).json({ error: error.message });
    if (error.type === 'entity.parse.failed') return res.status(400).json({ error: 'Invalid JSON.' });
    if (error.type === 'entity.too.large') return res.status(413).json({ error: 'Request is too large.' });
    // Never return API credentials, client secrets, or raw Stripe responses in errors.
    console.error('Payment request failed:', error.type ?? error.name);
    res.status(502).json({ error: 'Unable to reach the payment service. Please retry.' });
  });
  return app;
}
