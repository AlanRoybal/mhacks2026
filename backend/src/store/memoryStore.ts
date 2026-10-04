// In-process store for local dev and tests. Optionally snapshots to a JSON file so `tsx watch`
// restarts keep your data. Each method finishes its check-and-write before any await, so the
// version checks are atomic within the process.

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { LedgerEvent } from "../domain/events.js";
import type { Job, Offer, Proof, User } from "../domain/types.js";
import { AlreadyExistsError, byCreatedDesc, needsAttention, VersionConflictError, type Store } from "./store.js";

interface Snapshot {
  jobs: Record<string, Job>;
  users: Record<string, User>;
  offers: Record<string, Offer>;
  proofs: Record<string, Proof>;
  ledger: Record<string, LedgerEvent[]>;
  kv: Record<string, { value: unknown; expiresAt?: number }>;
}

const empty = (): Snapshot => ({ jobs: {}, users: {}, offers: {}, proofs: {}, ledger: {}, kv: {} });
const copy = <T>(v: T): T => structuredClone(v);

// Mirrors DynamoDB: attributes set to undefined are not stored.
function clean<T>(v: T): T {
  return JSON.parse(JSON.stringify(v)) as T;
}

export class MemoryStore implements Store {
  private data: Snapshot;

  constructor(private readonly file?: string) {
    this.data = file && existsSync(file) ? { ...empty(), ...(JSON.parse(readFileSync(file, "utf8")) as Partial<Snapshot>) } : empty();
  }

  private persist(): void {
    if (!this.file) return;
    mkdirSync(dirname(this.file), { recursive: true });
    const tmp = `${this.file}.tmp`;
    writeFileSync(tmp, JSON.stringify(this.data));
    renameSync(tmp, this.file);
  }

  async getJob(jobId: string) {
    const job = this.data.jobs[jobId];
    return job ? copy(job) : null;
  }

  async createJob(job: Job, created: LedgerEvent) {
    if (this.data.jobs[job.jobId]) throw new AlreadyExistsError(`Job ${job.jobId}`);
    this.data.jobs[job.jobId] = clean(job);
    this.data.ledger[job.jobId] = [clean(created)];
    this.persist();
  }

  async commitTransition(prevVersion: number, next: Job, event: LedgerEvent) {
    const current = this.data.jobs[next.jobId];
    if (!current || current.version !== prevVersion) throw new VersionConflictError(`Job ${next.jobId}`);
    const ledger = (this.data.ledger[next.jobId] ??= []);
    if (ledger.some((e) => e.seq === event.seq)) throw new VersionConflictError(`Ledger ${next.jobId}#${event.seq}`);
    this.data.jobs[next.jobId] = clean(next);
    ledger.push(clean(event));
    this.persist();
  }

  async saveJob(prevVersion: number, next: Job) {
    const current = this.data.jobs[next.jobId];
    if (!current || current.version !== prevVersion) throw new VersionConflictError(`Job ${next.jobId}`);
    this.data.jobs[next.jobId] = clean(next);
    this.persist();
  }

  async deleteJob(jobId: string, prevVersion: number) {
    const current = this.data.jobs[jobId];
    if (!current || current.version !== prevVersion) throw new VersionConflictError(`Job ${jobId}`);
    delete this.data.jobs[jobId];
    delete this.data.ledger[jobId];
    this.persist();
  }

  async listJobsByPoster(userId: string) {
    return Object.values(this.data.jobs).filter((j) => j.posterId === userId).sort(byCreatedDesc).map(copy);
  }

  async listJobsByWorker(userId: string) {
    return Object.values(this.data.jobs)
      .filter((j) => j.workerId === userId)
      .sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
      .map(copy);
  }

  async listJobsNeedingAttention() {
    return Object.values(this.data.jobs).filter(needsAttention).map(copy);
  }

  async listLedger(jobId: string) {
    return copy(this.data.ledger[jobId] ?? []).sort((a, b) => a.seq - b.seq);
  }

  async getUser(userId: string) {
    const user = this.data.users[userId];
    return user ? copy(user) : null;
  }

  async createUser(user: User) {
    if (this.data.users[user.userId]) throw new AlreadyExistsError(`User ${user.userId}`);
    this.data.users[user.userId] = clean(user);
    this.persist();
  }

  async saveUser(prevVersion: number, next: User) {
    const current = this.data.users[next.userId];
    if (!current || current.version !== prevVersion) throw new VersionConflictError(`User ${next.userId}`);
    this.data.users[next.userId] = clean(next);
    this.persist();
  }

  async listUsers() {
    return Object.values(this.data.users).map(copy);
  }

  async createOffers(offers: Offer[]) {
    for (const offer of offers) this.data.offers[offer.offerId] ??= clean(offer);
    this.persist();
  }

  async getOffer(offerId: string) {
    const offer = this.data.offers[offerId];
    return offer ? copy(offer) : null;
  }

  async updateOffer(offerId: string, patch: Partial<Offer>) {
    const offer = this.data.offers[offerId];
    if (!offer) return;
    this.data.offers[offerId] = clean({ ...offer, ...patch });
    this.persist();
  }

  async listOffersForJob(jobId: string) {
    return Object.values(this.data.offers)
      .filter((o) => o.jobId === jobId)
      .sort((a, b) => a.round - b.round || a.rank - b.rank)
      .map(copy);
  }

  async listOffersForWorker(workerId: string) {
    return Object.values(this.data.offers).filter((o) => o.workerId === workerId).sort(byCreatedDesc).map(copy);
  }

  async putProof(proof: Proof) {
    this.data.proofs[`${proof.jobId}/${proof.proofId}`] = clean(proof);
    this.persist();
  }

  async getProof(jobId: string, proofId: string) {
    const proof = this.data.proofs[`${jobId}/${proofId}`];
    return proof ? copy(proof) : null;
  }

  async listProofs(jobId: string) {
    return Object.values(this.data.proofs).filter((p) => p.jobId === jobId).sort(byCreatedDesc).map(copy);
  }

  private liveKv(key: string) {
    const entry = this.data.kv[key];
    if (!entry || (entry.expiresAt !== undefined && entry.expiresAt <= Date.now() / 1000)) return undefined;
    return entry;
  }

  async kvGet<T>(key: string) {
    const entry = this.liveKv(key);
    return entry ? (copy(entry.value) as T) : null;
  }

  async kvPut(key: string, value: unknown, opts: { ifAbsent?: boolean; ttlSeconds?: number } = {}) {
    // No await between the check and the write, so concurrent callers cannot both win.
    if (opts.ifAbsent && this.liveKv(key)) return false;
    const expiresAt = opts.ttlSeconds ? Math.floor(Date.now() / 1000) + opts.ttlSeconds : undefined;
    this.data.kv[key] = clean({ value, expiresAt });
    this.persist();
    return true;
  }
}
