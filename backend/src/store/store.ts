// Persistence port. Two implementations: MemoryStore (local dev, tests) and DynamoStore (deployed).
// Writes that guard money or assignment are conditional on the record's version.

import type { LedgerEvent } from "../domain/events.js";
import type { Job, Offer, Proof, User } from "../domain/types.js";

// Someone else changed the record first. Re-read and try again.
export class VersionConflictError extends Error {
  constructor(what: string) {
    super(`${what} was changed by another request`);
    this.name = "VersionConflictError";
  }
}

export class AlreadyExistsError extends Error {
  constructor(what: string) {
    super(`${what} already exists`);
    this.name = "AlreadyExistsError";
  }
}

export interface Store {
  getJob(jobId: string): Promise<Job | null>;
  // Creates the job and its first ledger row together.
  createJob(job: Job, created: LedgerEvent): Promise<void>;
  // Writes the next job and the ledger row atomically, only if the stored version is still prevVersion.
  commitTransition(prevVersion: number, next: Job, event: LedgerEvent): Promise<void>;
  // Saves a job edit that is not a state change (e.g. checklist edits on a draft).
  saveJob(prevVersion: number, next: Job): Promise<void>;
  deleteJob(jobId: string, prevVersion: number): Promise<void>;
  listJobsByPoster(userId: string): Promise<Job[]>;
  listJobsByWorker(userId: string): Promise<Job[]>;
  listLedger(jobId: string): Promise<LedgerEvent[]>;

  getUser(userId: string): Promise<User | null>;
  createUser(user: User): Promise<void>;
  saveUser(prevVersion: number, next: User): Promise<void>;
  listUsers(): Promise<User[]>;

  // Inserts offers that do not exist yet; existing ones are left untouched.
  createOffers(offers: Offer[]): Promise<void>;
  getOffer(offerId: string): Promise<Offer | null>;
  updateOffer(offerId: string, patch: Partial<Offer>): Promise<void>;
  listOffersForJob(jobId: string): Promise<Offer[]>;
  listOffersForWorker(workerId: string): Promise<Offer[]>;

  putProof(proof: Proof): Promise<void>;
  getProof(jobId: string, proofId: string): Promise<Proof | null>;
  listProofs(jobId: string): Promise<Proof[]>;

  // Small key-value records: identities, idempotency keys, cursors.
  kvGet<T>(key: string): Promise<T | null>;
  // Returns false when ifAbsent is set and a live value already exists.
  kvPut(key: string, value: unknown, opts?: { ifAbsent?: boolean; ttlSeconds?: number }): Promise<boolean>;
}

export const byCreatedDesc = <T extends { createdAt: string }>(a: T, b: T) => b.createdAt.localeCompare(a.createdAt);
