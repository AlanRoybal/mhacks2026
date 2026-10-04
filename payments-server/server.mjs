import { mkdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import Stripe from 'stripe';
import { JobStore, Payments } from './payments.mjs';
import { createApp } from './app.mjs';
import { Workers } from './workers.mjs';
import { Settlements } from './settlements.mjs';
import { CryptoPayments } from './crypto.mjs';

const secretKey = process.env.STRIPE_SECRET_KEY;
const publishableKey = process.env.STRIPE_PUBLISHABLE_KEY;
if (!/^(sk_test_|rk_test_|rkcs_test_)/.test(secretKey ?? '') || !publishableKey?.startsWith('pk_test_')) {
  throw new Error('Set test-mode STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY in payments-server/.env.');
}
mkdirSync(new URL('./data', import.meta.url), { recursive: true });
const stripe = new Stripe(secretKey, { maxNetworkRetries: 2, timeout: 20_000 });
const store = new JobStore(fileURLToPath(new URL('./data/jobs.sqlite', import.meta.url)));
const payments = new Payments({ stripe, store, publishableKey });
const workers = new Workers({ store, stripe, publicURL: process.env.BOUNTY_PUBLIC_URL ?? 'http://127.0.0.1:4242' });
const crypto = process.env.ESCROW_CONTRACT_ADDRESS ? new CryptoPayments({ store,
  rpcURL: process.env.BASE_SEPOLIA_RPC_URL ?? 'https://sepolia.base.org', address: process.env.ESCROW_CONTRACT_ADDRESS,
  privateKey: process.env.ESCROW_ARBITER_PRIVATE_KEY, deploymentBlock: process.env.ESCROW_DEPLOYMENT_BLOCK ?? 0 }) : null;
const settlements = new Settlements({ store, stripe, workers, crypto });
if (crypto) crypto.settlements = settlements;
const app = createApp({ payments, stripe, workers, settlements, crypto, adminToken: process.env.BOUNTY_ADMIN_TOKEN,
  webhookSecret: process.env.STRIPE_WEBHOOK_SECRET });
const port = Number(process.env.PORT ?? 4242);
const host = process.env.HOST ?? '127.0.0.1';
const server = app.listen(port, host, () => console.log(`Bounty test payments: http://${host}:${port}`));
const timer = setInterval(() => settlements.recover().catch(() => {}), 10_000);
timer.unref();
const shutdown = () => { clearInterval(timer); server.close(() => { store.close(); process.exit(0); }); };
process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
