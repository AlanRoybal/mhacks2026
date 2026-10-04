import { spawn } from 'node:child_process';
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

if (!/^(sk_test_|rk_test_|rkcs_test_)/.test(process.env.STRIPE_SECRET_KEY ?? '')) throw new Error('Use a Stripe test key.');
const cli = fileURLToPath(new URL('./node_modules/.bin/stripe', import.meta.url));
const child = spawn(cli, ['listen', '--events', 'payment_intent.succeeded,payment_intent.payment_failed,payment_intent.processing,payment_intent.canceled',
  '--forward-to', 'http://127.0.0.1:4242/stripe/webhook'], {
  env: { ...process.env, STRIPE_API_KEY: process.env.STRIPE_SECRET_KEY }, stdio: ['ignore', 'pipe', 'pipe'],
});
const consume = stream => {
  let buffered = '';
  stream.setEncoding('utf8');
  stream.on('data', data => {
    buffered += data;
    const lines = buffered.split('\n'); buffered = lines.pop();
    for (const line of lines) {
      const secret = line.match(/whsec_[A-Za-z0-9]+/)?.[0];
      if (secret) {
        const path = new URL('./.env', import.meta.url);
        let env = readFileSync(path, 'utf8');
        env = /^STRIPE_WEBHOOK_SECRET=/m.test(env)
          ? env.replace(/^STRIPE_WEBHOOK_SECRET=.*$/m, `STRIPE_WEBHOOK_SECRET=${secret}`)
          : `${env}\nSTRIPE_WEBHOOK_SECRET=${secret}\n`;
        writeFileSync(path, env, { mode: 0o600 });
        console.log('Webhook signing secret saved to .env. Start/restart the backend now.');
      } else console.log(line.replace(/(?:sk_test_|rk_test_|rkcs_test_|pk_test_)[A-Za-z0-9_]+/g, '[redacted]'));
    }
  });
};
consume(child.stdout); consume(child.stderr);
child.on('error', () => { console.error('Unable to start the Stripe CLI listener.'); process.exitCode = 1; });
child.on('exit', code => { process.exitCode = code ?? 0; });
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => child.kill('SIGTERM'));
