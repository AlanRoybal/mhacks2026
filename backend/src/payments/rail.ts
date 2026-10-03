import type { Job, User } from "../domain/types.js";

// What the app needs to collect payment. Field names match FundingSession in the iOS app
// (Bounty/Services/JobsAPI.swift). provider "fake" means funding already confirmed: skip the sheet.
export interface FundingSession {
  provider: "stripe" | "fake";
  paymentIntentId: string | null;
  paymentIntentClientSecret: string;
  customerId: string | null;
  ephemeralKeySecret: string | null;
  publishableKey: string;
}

// A way of holding and moving a job's money. Calls must be idempotent per job: the outbox may retry.
export interface PaymentRail {
  // Starts (or resumes) checkout for a draft. Funding is confirmed later by FUND_CONFIRMED.
  startFunding(job: Job, poster: User): Promise<FundingSession>;
  // Sends the bounty to the worker.
  payout(job: Job, worker: User): Promise<{ transferId: string }>;
  // Returns the full charge (bounty + fee) to the poster.
  refund(job: Job): Promise<{ refundId: string }>;
}

export class RailUnavailableError extends Error {
  constructor(rail: string) {
    super(`The ${rail} payment rail is not available yet`);
    this.name = "RailUnavailableError";
  }
}
