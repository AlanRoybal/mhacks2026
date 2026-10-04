import { DatabaseSync } from 'node:sqlite';
import { randomUUID } from 'node:crypto';

export class PaymentError extends Error {
  constructor(status, message) { super(message); this.status = status; }
}

export function validateDraft(input) {
  if (!input || typeof input !== 'object') throw new PaymentError(400, 'A job is required.');
  if (typeof input.id !== 'string' || !/^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$/i.test(input.id)) {
    throw new PaymentError(400, 'A valid job ID is required.');
  }
  const text = (key, max) => {
    if (typeof input[key] !== 'string' || !input[key].trim() || input[key].trim().length > max) {
      throw new PaymentError(400, `Invalid ${key}.`);
    }
    return input[key].trim();
  };
  if (!Number.isSafeInteger(input.amountCents) || input.amountCents < 50 || input.amountCents > 1_000_000) {
    throw new PaymentError(400, 'Job pay must be between $0.50 and $10,000, in whole cents.');
  }
  const deadline = new Date(input.deadline);
  if (!Number.isFinite(deadline.getTime()) || deadline <= new Date()) {
    throw new PaymentError(400, 'Choose a future deadline.');
  }
  if (typeof input.isRemote !== 'boolean') throw new PaymentError(400, 'Choose a job location.');
  const category = text('category', 40);
  if (!['Design', 'Home', 'Tutoring', 'Photography', 'Technology'].includes(category)) {
    throw new PaymentError(400, 'Choose a supported category.');
  }
  return {
    id: input.id.toLowerCase(), title: text('title', 120), details: text('details', 4000),
    category, isRemote: input.isRemote, deadline: deadline.toISOString(), amountCents: input.amountCents,
  };
}

export class JobStore {
  constructor(path = ':memory:') {
    this.db = new DatabaseSync(path);
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      PRAGMA foreign_keys = ON;
      PRAGMA busy_timeout = 5000;
      CREATE TABLE IF NOT EXISTS jobs (id TEXT PRIMARY KEY, record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS LedgerEvents (
        id TEXT PRIMARY KEY,
        job_id TEXT NOT NULL REFERENCES jobs(id),
        type TEXT NOT NULL,
        payment_intent_id TEXT NOT NULL,
        stripe_event_id TEXT,
        record TEXT NOT NULL,
        UNIQUE (job_id, type),
        UNIQUE (payment_intent_id, type)
      );
      CREATE TRIGGER IF NOT EXISTS ledger_events_no_update BEFORE UPDATE ON LedgerEvents
        BEGIN SELECT RAISE(ABORT, 'LedgerEvents is append-only'); END;
      CREATE TRIGGER IF NOT EXISTS ledger_events_no_delete BEFORE DELETE ON LedgerEvents
        BEGIN SELECT RAISE(ABORT, 'LedgerEvents is append-only'); END;
      CREATE TABLE IF NOT EXISTS workers (id TEXT PRIMARY KEY, token_hash TEXT UNIQUE NOT NULL, record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS SettlementOperations (job_id TEXT PRIMARY KEY REFERENCES jobs(id), record TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS ChainWrites (id TEXT PRIMARY KEY, record TEXT NOT NULL);
    `);
  }
  get(id) {
    const row = this.db.prepare('SELECT record FROM jobs WHERE id = ?').get(id);
    return row ? JSON.parse(row.record) : null;
  }
  save(job) {
    this.db.prepare('INSERT INTO jobs (id, record) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record')
      .run(job.id, JSON.stringify(job));
    return job;
  }
  transaction(operation) {
    this.db.exec('BEGIN IMMEDIATE');
    try {
      const result = operation();
      this.db.exec('COMMIT');
      return result;
    } catch (error) {
      this.db.exec('ROLLBACK');
      throw error;
    }
  }
  appendFunding(job, { source, stripeEventID, reference }) {
    this.appendLedger(job, 'JOB_FUNDED', { fromStatus: 'draft', toStatus: 'funded', stripeEventID, source, reference });
  }
  appendLedger(job, type, details = {}) {
    const event = { id: randomUUID(), jobID: job.id, type, paymentIntentID: job.paymentIntentID ?? null,
      fundingRail: job.fundingRail ?? 'stripe', workerID: job.workerID ?? null,
      amountCents: job.amountCents, feeCents: job.feeCents, totalCents: job.totalCents,
      currency: job.currency, createdAt: new Date().toISOString(), ...details };
    this.db.prepare(`INSERT INTO LedgerEvents
      (id, job_id, type, payment_intent_id, stripe_event_id, record) VALUES (?, ?, ?, ?, ?, ?)`)
      .run(event.id, event.jobID, event.type, job.paymentIntentID ?? job.chainJobID, event.stripeEventID ?? null, JSON.stringify(event));
  }
  ledgerEvents(id) {
    return this.db.prepare('SELECT record FROM LedgerEvents WHERE job_id = ? ORDER BY rowid')
      .all(id).map(row => JSON.parse(row.record));
  }
  list() { return this.db.prepare('SELECT record FROM jobs ORDER BY rowid DESC').all().map(row => JSON.parse(row.record)); }
  operation(id) {
    const row = this.db.prepare('SELECT record FROM SettlementOperations WHERE job_id = ?').get(id);
    return row ? JSON.parse(row.record) : null;
  }
  saveOperation(operation) {
    this.db.prepare('INSERT INTO SettlementOperations (job_id, record) VALUES (?, ?) ON CONFLICT(job_id) DO UPDATE SET record = excluded.record')
      .run(operation.jobID, JSON.stringify(operation));
    return operation;
  }
  chainWrite(id) {
    const row = this.db.prepare('SELECT record FROM ChainWrites WHERE id = ?').get(id);
    return row ? JSON.parse(row.record) : null;
  }
  saveChainWrite(id, record) {
    this.db.prepare('INSERT INTO ChainWrites (id, record) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET record = excluded.record')
      .run(id, JSON.stringify(record));
  }
  close() { this.db.close(); }
}

export class Payments {
  constructor({ stripe, store, publishableKey }) {
    this.stripe = stripe; this.store = store; this.publishableKey = publishableKey;
    this.inFlight = new Map();
  }

  async prepare(input) {
    const draft = validateDraft(input);
    // A retry after a timeout, cancellation, or concurrent tap must reuse the same charge.
    if (this.inFlight.has(draft.id)) {
      await this.inFlight.get(draft.id);
      return this.prepare(input);
    }
    const operation = this.createSheet(draft);
    this.inFlight.set(draft.id, operation);
    try { return await operation; }
    finally { this.inFlight.delete(draft.id); }
  }

  async createSheet(draft) {
    let job = this.store.get(draft.id);
    if (job?.fundingRail === 'usdc') throw new PaymentError(409, 'This checkout already uses USDC. Start a new checkout to pay by card.');
    if (job && JSON.stringify(job.draft) !== JSON.stringify(draft)) {
      throw new PaymentError(409, 'This checkout already belongs to another job. Start a new checkout.');
    }
    if (!job) {
      const feeCents = Math.round(draft.amountCents * 0.10);
      job = this.store.save({ ...draft, draft, feeCents, totalCents: draft.amountCents + feeCents,
        currency: 'usd', fundingRail: 'stripe', status: 'draft', paymentIntentID: null });
    }
    const intent = job.paymentIntentID
      ? await this.stripe.paymentIntents.retrieve(job.paymentIntentID)
      : await this.stripe.paymentIntents.create({
          amount: job.totalCents, currency: job.currency,
          allowed_payment_method_types: ['card'],
          description: `Bounty: ${job.title}`,
          metadata: { job_id: job.id }, transfer_group: `job_${job.id}`,
        }, { idempotencyKey: `bounty-funding-${job.id}` });
    // A webhook may have funded the job while the Stripe request was in flight.
    // Read the latest row before binding the intent, rather than saving stale status.
    job = this.store.transaction(() => {
      const current = this.store.get(draft.id);
      if (current.paymentIntentID && current.paymentIntentID !== intent.id) {
        throw new PaymentError(409, 'This checkout already has a payment.');
      }
      current.paymentIntentID = intent.id;
      return this.store.save(current);
    });
    job = this.applyIntent(intent);
    if (intent.status === 'canceled') throw new PaymentError(409, 'This payment expired. Start a new checkout.');
    return { job: this.publicJob(job), paymentIntentClientSecret: intent.client_secret,
      publishableKey: this.publishableKey };
  }

  applyIntent(intent, { source = 'reconciliation', stripeEventID = null } = {}) {
    if (typeof intent.metadata?.job_id !== 'string') return null;
    return this.store.transaction(() => {
      const job = this.store.get(intent.metadata.job_id);
      if (!job || job.paymentIntentID !== intent.id) return null;
      if (intent.livemode !== false || intent.amount !== job.totalCents || intent.currency !== job.currency) {
        throw new PaymentError(409, 'Payment details do not match this job.');
      }
      if (intent.status === 'succeeded') {
        if (intent.amount_received !== job.totalCents) throw new PaymentError(409, 'The full job payment has not been received.');
        if (job.status === 'draft') {
          this.store.appendFunding(job, { source, stripeEventID });
          job.status = 'funded';
          return this.store.save(job);
        }
      }
      // Duplicates and older failure/processing events never undo a transition.
      return job;
    });
  }

  async status(id) {
    const job = this.store.get(id.toLowerCase());
    if (!job) throw new PaymentError(404, 'Job not found.');
    if (job.paymentIntentID && job.status === 'draft') {
      const intent = await this.stripe.paymentIntents.retrieve(job.paymentIntentID);
      return this.publicJob(this.applyIntent(intent));
    }
    return this.publicJob(job);
  }

  publicJob(job) {
    const { draft, paymentIntentID, ...safe } = job;
    return safe;
  }
}
