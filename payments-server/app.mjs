import express from 'express';
import { PaymentError } from './payments.mjs';

export function createApp({ payments, stripe, webhookSecret }) {
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
      if (['payment_intent.succeeded', 'payment_intent.payment_failed', 'payment_intent.processing'].includes(event.type)) {
        payments.applyIntent(event.data.object);
      }
      res.json({ received: true });
    } catch (error) { next(error); }
  });
  app.use(express.json({ limit: '16kb' }));
  app.get('/health', (req, res) => res.json({ status: 'ok', mode: 'test' }));
  app.post('/payment-sheet', async (req, res, next) => {
    try { res.json(await payments.prepare(req.body)); } catch (error) { next(error); }
  });
  app.get('/jobs/:id', async (req, res, next) => {
    try { res.json(await payments.status(req.params.id)); } catch (error) { next(error); }
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
