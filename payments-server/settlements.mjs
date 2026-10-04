import { randomUUID } from 'node:crypto';
import { PaymentError } from './payments.mjs';

export class Settlements {
  constructor({ store, stripe, workers, crypto, clock = () => Date.now() }) {
    Object.assign(this, { store, stripe, workers, crypto, clock });
    this.inFlight = new Map();
  }
  job(id) {
    const job = this.store.get(id.toLowerCase());
    if (!job) throw new PaymentError(404, 'Job not found.');
    return job;
  }
  async assign(id, workerID) {
    const job = this.job(id);
    const worker = this.workers.get(workerID);
    const destination = await this.workers.destination(worker, job.fundingRail ?? 'stripe');
    return this.store.transaction(() => {
      const current = this.job(id);
      if (current.workerID === workerID && current.workerDestination === destination) return current;
      if (current.status !== 'funded' || this.store.operation(current.id)) throw new PaymentError(409, 'Only a funded, unassigned job can be assigned.');
      current.workerID = workerID; current.workerDestination = destination; current.status = 'accepted';
      this.store.appendLedger(current, 'JOB_ASSIGNED', { fromStatus: 'funded', toStatus: 'accepted', destination });
      return this.store.save(current);
    });
  }
  review(id, seconds = 120) {
    if (!Number.isSafeInteger(seconds) || seconds < 1 || seconds > 172800) throw new PaymentError(400, 'Review window must be 1 second to 48 hours.');
    return this.store.transaction(() => {
      const job = this.job(id);
      if (!['accepted', 'in_progress'].includes(job.status) || new Date(job.deadline).getTime() <= this.clock()) {
        throw new PaymentError(409, 'Only work submitted before its deadline can enter review.');
      }
      const previous = job.status;
      job.status = 'in_review'; job.reviewEndsAt = new Date(this.clock() + seconds * 1000).toISOString();
      this.store.appendLedger(job, 'JOB_IN_REVIEW', { fromStatus: previous, toStatus: job.status, reviewEndsAt: job.reviewEndsAt });
      return this.store.save(job);
    });
  }
  reserve(id, kind) {
    return this.store.transaction(() => {
      const job = this.job(id);
      const previous = this.store.operation(job.id);
      if (previous) {
        if (previous.kind !== kind) throw new PaymentError(409, 'A conflicting settlement has already been reserved.');
        return previous;
      }
      if (kind === 'release' && (job.status !== 'in_review' || !job.workerID || !job.workerDestination)) {
        throw new PaymentError(409, 'A reviewed job and its assigned worker are required for release.');
      }
      if (kind === 'refund') {
        const expired = new Date(job.deadline).getTime() <= this.clock();
        if (!['funded', 'accepted', 'in_progress'].includes(job.status) || (!expired && (job.status !== 'funded' || job.fundingRail === 'usdc'))) {
          throw new PaymentError(409, 'This job is not eligible for a refund.');
        }
      }
      const operation = { id: randomUUID(), jobID: job.id, kind, phase: 'pending',
        createdAt: this.clock(), destination: job.workerDestination ?? null, workerID: job.workerID ?? null };
      this.store.saveOperation(operation);
      const fromStatus = job.status;
      job.status = `${kind}_pending`;
      this.store.appendLedger(job, kind === 'release' ? 'RELEASE_REQUESTED' : 'REFUND_REQUESTED',
        { fromStatus, toStatus: job.status, operationID: operation.id });
      this.store.save(job);
      return operation;
    });
  }
  async settle(id, kind) {
    const operation = this.reserve(id, kind);
    if (operation.phase === 'complete') return this.job(id);
    if (this.inFlight.has(operation.jobID)) return this.inFlight.get(operation.jobID);
    const run = this.execute(operation);
    this.inFlight.set(operation.jobID, run);
    try { return await run; } finally { this.inFlight.delete(operation.jobID); }
  }
  async execute(operation) {
    const job = this.job(operation.jobID);
    try {
      if (job.fundingRail === 'usdc') {
        if (!this.crypto) throw new PaymentError(503, 'USDC settlement is not configured.');
        await this.crypto.settle(job, operation);
        return this.job(job.id);
      }
      const intent = await this.stripe.paymentIntents.retrieve(job.paymentIntentID);
      const charge = this.validateFunding(job, intent);
      const params = operation.kind === 'release'
        ? { amount: job.amountCents, currency: 'usd', destination: operation.destination, source_transaction: charge,
            transfer_group: `job_${job.id}`, metadata: { job_id: job.id, worker_id: operation.workerID, operation_id: operation.id } }
        : { payment_intent: job.paymentIntentID, amount: job.totalCents, metadata: { job_id: job.id, operation_id: operation.id } };
      const api = operation.kind === 'release' ? this.stripe.transfers : this.stripe.refunds;
      let result;
      if (operation.reference) result = await api.retrieve(operation.reference);
      else {
        if (this.clock() - operation.createdAt > 23 * 60 * 60 * 1000) {
          // Stripe can expire idempotency keys after 24h. Never blindly create again.
          const listed = operation.kind === 'release'
            ? await api.list({ transfer_group: `job_${job.id}`, limit: 100 })
            : await api.list({ payment_intent: job.paymentIntentID, limit: 100 });
          const matches = listed.data.filter(value => value.metadata?.operation_id === operation.id);
          if (matches.length !== 1) throw new PaymentError(409, 'An old settlement needs reconciliation before retrying.');
          result = matches[0];
        } else result = await api.create(params, { idempotencyKey: `bounty-${operation.kind}-${operation.id}` });
      }
      this.validateResult(job, operation, result, charge);
      operation.reference = result.id;
      this.store.saveOperation(operation);
      if (operation.kind === 'refund' && result.status !== 'succeeded') {
        if (result.status === 'failed' || result.status === 'canceled') throw new PaymentError(409, 'The refund failed. Its record requires reconciliation.');
        return job;
      }
      return this.finish(job.id, operation.kind, result.id, { source: 'stripe', destination: operation.destination });
    } catch (error) {
      const current = this.store.operation(operation.jobID);
      if (current?.phase !== 'complete') this.store.saveOperation({ ...current, lastError: error instanceof PaymentError ? error.message : 'Settlement failed; retry the same operation.' });
      throw error;
    }
  }
  validateFunding(job, intent) {
    const charge = typeof intent?.latest_charge === 'string' ? intent.latest_charge : intent?.latest_charge?.id;
    if (intent?.id !== job.paymentIntentID || intent.livemode !== false || intent.status !== 'succeeded'
        || intent.amount !== job.totalCents || intent.amount_received !== job.totalCents
        || intent.currency !== 'usd' || intent.metadata?.job_id !== job.id || !charge) {
      throw new PaymentError(409, 'The original test payment does not match this funded job.');
    }
    return charge;
  }
  validateResult(job, operation, result, charge) {
    const release = operation.kind === 'release';
    const destination = typeof result?.destination === 'string' ? result.destination : result?.destination?.id;
    const source = typeof result?.source_transaction === 'string' ? result.source_transaction : result?.source_transaction?.id;
    // Refund objects have no livemode field; the verified parent intent proves test mode.
    if (!result || (release ? result.livemode !== false : result.livemode === true) || result.amount !== (release ? job.amountCents : job.totalCents)
        || result.currency !== 'usd' || result.metadata?.job_id !== job.id || result.metadata?.operation_id !== operation.id
        || (release && (destination !== operation.destination || result.reversed || result.amount_reversed > 0
          || result.metadata?.worker_id !== operation.workerID || source !== charge || result.transfer_group !== `job_${job.id}`))
        || (!release && result.payment_intent !== job.paymentIntentID)) {
      throw new PaymentError(409, 'The settlement result does not match this job and recipient.');
    }
  }
  finish(id, kind, reference, details = {}) {
    return this.store.transaction(() => {
      const job = this.job(id);
      const target = kind === 'release' ? 'released' : 'refunded';
      if (job.status === target) return job;
      if (['released', 'refunded'].includes(job.status)) throw new PaymentError(409, 'This job has a conflicting terminal settlement.');
      const operation = this.store.operation(job.id);
      if (kind === 'release' && (!operation || operation.kind !== kind)) throw new PaymentError(409, 'Release decision missing.');
      const fromStatus = job.status;
      job.status = target; job.settlementReference = reference;
      this.store.appendLedger(job, kind === 'release' ? 'JOB_RELEASED' : 'JOB_REFUNDED',
        { fromStatus, toStatus: target, reference, ...details });
      if (operation) this.store.saveOperation({ ...operation, phase: 'complete', outcome: kind, reference, lastError: null });
      return this.store.save(job);
    });
  }
  earnings(workerID) {
    const jobs = this.store.list().filter(job => job.workerID === workerID);
    const totals = { usd: { pendingCents: 0, releasedCents: 0 }, usdc: { pendingCents: 0, releasedCents: 0 } };
    const entries = jobs.map(job => {
      const rail = job.fundingRail === 'usdc' ? 'usdc' : 'usd';
      const paid = this.store.ledgerEvents(job.id).some(event => event.type === 'JOB_RELEASED' && event.workerID === workerID);
      if (paid && job.status === 'released') totals[rail].releasedCents += job.amountCents;
      else if (['accepted', 'in_progress', 'in_review', 'release_pending'].includes(job.status)) totals[rail].pendingCents += job.amountCents;
      return { jobID: job.id, title: job.title, amountCents: job.amountCents, rail, status: job.status, reference: job.settlementReference ?? null };
    });
    return { totals, entries };
  }
  async verifiedEarnings(workerID) {
    const result = this.earnings(workerID);
    // Recheck actual money movement before presenting released earnings.
    for (const entry of result.entries.filter(value => value.status === 'released')) {
      let consistent = false;
      try { consistent = (await this.audit(entry.jobID)).consistent; } catch {}
      if (!consistent) {
        if (this.store.ledgerEvents(entry.jobID).some(event => event.type === 'JOB_RELEASED' && event.workerID === workerID)) {
          result.totals[entry.rail].releasedCents -= entry.amountCents;
        }
        entry.status = 'settlement_issue';
        entry.issue = 'Payment needs reconciliation. Refresh or contact the platform.';
      }
    }
    return result;
  }
  async recover() {
    if (this.recovering) return;
    this.recovering = true;
    try {
      if (this.crypto) await this.crypto.reconcileAll();
      for (const job of this.store.list()) {
        try {
          const operation = this.store.operation(job.id);
          if (operation?.phase === 'pending') await this.settle(job.id, operation.kind);
          else if (job.status === 'in_review' && new Date(job.reviewEndsAt).getTime() <= this.clock()) await this.settle(job.id, 'release');
          else if (['funded', 'accepted', 'in_progress'].includes(job.status) && new Date(job.deadline).getTime() <= this.clock()) await this.settle(job.id, 'refund');
        } catch { /* Persistent pending operation keeps the retry safe. Audit exposes errors. */ }
      }
    } finally { this.recovering = false; }
  }
  async audit(id) {
    const job = this.job(id);
    const events = this.store.ledgerEvents(job.id);
    const issues = [];
    const released = events.filter(event => event.type === 'JOB_RELEASED');
    const refunded = events.filter(event => event.type === 'JOB_REFUNDED');
    if (released.length && refunded.length) issues.push('Both terminal ledger events exist.');
    if (job.status === 'released' && released.length !== 1) issues.push('Released job is missing its ledger record.');
    if (job.status === 'refunded' && refunded.length !== 1) issues.push('Refunded job is missing its ledger record.');
    if (job.status !== 'draft' && !events.some(event => event.type === 'JOB_FUNDED')) issues.push('Funding ledger record is missing.');
    const operation = this.store.operation(job.id);
    for (const event of events) {
      if (event.jobID !== job.id || event.amountCents !== job.amountCents || event.totalCents !== job.totalCents
          || event.currency !== job.currency) issues.push('Ledger amounts or job identity do not match.');
    }
    const terminal = job.status === 'released' ? released[0] : job.status === 'refunded' ? refunded[0] : null;
    if (terminal && terminal.reference !== job.settlementReference) issues.push('Terminal ledger reference does not match the job.');
    if (job.status === 'released' && terminal && (terminal.workerID !== job.workerID || terminal.destination !== job.workerDestination)) issues.push('Release ledger recipient does not match.');
    if (job.status === 'released' && (!operation || operation.phase !== 'complete' || operation.outcome !== 'release'
        || operation.workerID !== job.workerID || operation.destination !== job.workerDestination)) issues.push('Release operation does not match its assigned worker.');
    if (operation?.phase === 'pending') issues.push(operation.lastError ?? 'Settlement is pending confirmation.');
    if (job.fundingRail === 'usdc') {
      if (!this.crypto) issues.push('Chain client unavailable.');
      else issues.push(...await this.crypto.audit(job));
    } else {
      const intent = await this.stripe.paymentIntents.retrieve(job.paymentIntentID);
      let charge;
      if (job.status !== 'draft') {
        try { charge = this.validateFunding(job, intent); } catch { issues.push('Stripe funding does not match.'); }
      }
      if (operation?.reference) {
        try {
          const api = operation.outcome === 'refund' || operation.kind === 'refund' ? this.stripe.refunds : this.stripe.transfers;
          const result = await api.retrieve(operation.reference);
          this.validateResult(job, operation, result, charge);
          if (operation.kind === 'refund' && job.status === 'refunded' && result.status !== 'succeeded') issues.push('Refund has not succeeded at Stripe.');
        } catch { issues.push('Stripe settlement does not match the ledger.'); }
      }
    }
    return { jobID: job.id, status: job.status, consistent: issues.length === 0, issues, events };
  }
}
