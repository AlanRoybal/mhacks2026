import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import Stripe from 'stripe';
import { JobStore, Payments } from './payments.mjs';
import { createApp } from './app.mjs';

const secretKey = process.env.STRIPE_SECRET_KEY;
const publishableKey = process.env.STRIPE_PUBLISHABLE_KEY;
if (!/^(sk_test_|rk_test_|rkcs_test_)/.test(secretKey ?? '') || !publishableKey?.startsWith('pk_test_')) {
  throw new Error('Set test-mode STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY in backend/.env.');
}
mkdirSync(new URL('./data', import.meta.url), { recursive: true });
const stripe = new Stripe(secretKey, { maxNetworkRetries: 2, timeout: 20_000 });
const store = new JobStore(fileURLToPath(new URL('./data/jobs.sqlite', import.meta.url)));
const payments = new Payments({ stripe, store, publishableKey });
const app = createApp({ payments, stripe, webhookSecret: process.env.STRIPE_WEBHOOK_SECRET });
const port = Number(process.env.PORT ?? 4242);
const host = process.env.HOST ?? '127.0.0.1';
const server = app.listen(port, host, () => console.log(`Bounty test payments: http://${host}:${port}`));
const shutdown = () => server.close(() => { store.close(); process.exit(0); });
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
