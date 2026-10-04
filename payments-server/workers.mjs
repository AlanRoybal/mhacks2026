import { randomUUID, randomBytes, createHash } from 'node:crypto';
import { getAddress, verifyMessage } from 'viem';
import { PaymentError } from './payments.mjs';

const hash = token => createHash('sha256').update(token).digest('hex');
export class Workers {
  constructor({ store, stripe, publicURL }) { this.store = store; this.stripe = stripe; this.publicURL = publicURL; }
  create() {
    const token = randomBytes(32).toString('hex');
    const worker = { id: randomUUID(), connectAccountID: null, walletAddress: null };
    this.store.db.prepare('INSERT INTO workers (id, token_hash, record) VALUES (?, ?, ?)').run(worker.id, hash(token), JSON.stringify(worker));
    return { worker, token };
  }
  authenticate(token) {
    if (typeof token !== 'string' || !/^[0-9a-f]{64}$/.test(token)) throw new PaymentError(401, 'A worker session is required.');
    const row = this.store.db.prepare('SELECT record FROM workers WHERE token_hash = ?').get(hash(token));
    if (!row) throw new PaymentError(401, 'Invalid worker session.');
    return JSON.parse(row.record);
  }
  get(id) {
    const row = this.store.db.prepare('SELECT record FROM workers WHERE id = ?').get(id);
    if (!row) throw new PaymentError(404, 'Worker not found.');
    return JSON.parse(row.record);
  }
  save(worker) {
    this.store.db.prepare('UPDATE workers SET record = ? WHERE id = ?').run(JSON.stringify(worker), worker.id);
    return worker;
  }
  publicWorker(worker) {
    const { challenge, ...safe } = worker;
    return safe;
  }
  list() {
    return this.store.db.prepare('SELECT record FROM workers ORDER BY rowid DESC').all()
      .map(row => this.publicWorker(JSON.parse(row.record)));
  }
  async connect(worker) {
    const account = worker.connectAccountID
      ? await this.stripe.accounts.retrieve(worker.connectAccountID)
      : await this.stripe.accounts.create({ type: 'express', country: 'US', capabilities: { transfers: { requested: true } },
          metadata: { worker_id: worker.id } }, { idempotencyKey: `bounty-worker-${worker.id}` });
    if (account.metadata?.worker_id !== worker.id) throw new PaymentError(409, 'Connect account does not belong to this worker.');
    this.save({ ...this.get(worker.id), connectAccountID: account.id });
    if (!this.publicURL) throw new PaymentError(503, 'Configure BOUNTY_PUBLIC_URL for Connect onboarding.');
    const link = await this.stripe.accountLinks.create({ account: account.id, type: 'account_onboarding',
      refresh_url: `${this.publicURL}/connect/refresh`, return_url: `${this.publicURL}/connect/return` });
    return { url: link.url };
  }
  challenge(worker, address) {
    let normalized;
    try { normalized = getAddress(address); } catch { throw new PaymentError(400, 'A valid wallet address is required.'); }
    const message = `Bounty test worker wallet\nWorker: ${worker.id}\nAddress: ${normalized}\nChain: 84532\nNonce: ${randomBytes(24).toString('hex')}`;
    this.save({ ...worker, challenge: { address: normalized, message, expiresAt: Date.now() + 300_000 } });
    return { message };
  }
  async verifyWallet(worker, signature) {
    const challenge = worker.challenge;
    if (!challenge || challenge.expiresAt < Date.now()) throw new PaymentError(400, 'Wallet challenge expired. Request another.');
    let verified = false;
    try { verified = await verifyMessage({ address: challenge.address, message: challenge.message, signature }); } catch {}
    if (!verified) throw new PaymentError(401, 'The wallet signature did not match.');
    return this.store.transaction(() => {
      const current = this.get(worker.id);
      if (current.challenge?.message !== challenge.message) throw new PaymentError(409, 'Wallet challenge already used.');
      delete current.challenge;
      current.walletAddress = challenge.address;
      return this.publicWorker(this.save(current));
    });
  }
  async destination(worker, rail) {
    if (rail === 'usdc') {
      if (!worker.walletAddress) throw new PaymentError(409, 'The worker must verify a payout wallet first.');
      return worker.walletAddress;
    }
    if (!worker.connectAccountID) throw new PaymentError(409, 'The worker must finish Connect onboarding first.');
    const account = await this.stripe.accounts.retrieve(worker.connectAccountID);
    if (account.deleted || account.metadata?.worker_id !== worker.id || account.capabilities?.transfers !== 'active') {
      throw new PaymentError(409, 'This worker’s Connect account is not ready for transfers.');
    }
    return account.id;
  }
}
