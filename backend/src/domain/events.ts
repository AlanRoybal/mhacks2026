import type { Actor, GradeDecision, JobState, LatLng, OfferStatus, UserStats } from "./types.js";

// Everything that can happen to a job. Only jobMachine.transition() decides whether it is allowed.
export type JobEvent =
  | { type: "FUND_CONFIRMED"; amountCents: number; paymentIntentId?: string; chargeId?: string }
  | { type: "OFFER_SENT"; offerId: string; workerId: string; expiresAt: string }
  | { type: "OFFER_DECLINED"; offerId: string }
  | { type: "OFFER_EXPIRED"; offerId: string }
  | { type: "CANDIDATES_EXHAUSTED"; round: number }
  | { type: "REMATCH"; round: number }
  | { type: "ACCEPT"; offerId: string }
  | { type: "CANCEL" }
  | { type: "UPDATE_TERMS"; deadline?: string; radiusKm?: number }
  | { type: "START"; captureKey: string; at?: LatLng; accuracyM?: number }
  | { type: "WITHDRAW" }
  | { type: "SUBMIT"; proofId: string }
  | { type: "GRADED"; proofId: string; decision: GradeDecision; summary: string }
  | { type: "GRADE_TIMEOUT"; proofId: string }
  | { type: "APPROVE" }
  | { type: "REJECT" }
  | { type: "REVIEW_WINDOW_EXPIRED" }
  | { type: "DISPUTE"; itemId: string; reason: string }
  | { type: "RESOLVE"; outcome: "release" | "refund"; note?: string }
  | { type: "DISPUTE_TIMEOUT" }
  | { type: "DEADLINE_PASSED" }
  | { type: "PAYOUT_CONFIRMED"; transferId: string }
  | { type: "REFUND_CONFIRMED"; refundId: string }
  | { type: "RATE"; stars: number; comment?: string };

export type JobEventType = JobEvent["type"];

export type TimerKind = "offer_expire" | "review_window" | "deadline" | "rematch" | "grade_timeout" | "dispute_timeout";

export type PushTemplate =
  | "offer"
  | "offer_closed"
  | "offer_accepted"
  | "job_canceled"
  | "worker_withdrew"
  | "no_match_yet"
  | "proof_ready"
  | "proof_needs_decision"
  | "proof_passed"
  | "proof_failed"
  | "proof_escalated"
  | "disputed"
  | "resolved"
  | "work_rejected"
  | "deadline_missed"
  | "unmatched_refund"
  | "paid"
  | "refunded";

export type StatKey = keyof UserStats;

// Side effects requested by a transition. They are stored on the ledger row and run after commit,
// so they must be safe to run more than once.
export type Effect =
  | { kind: "match" }
  | { kind: "offer.next" }
  | { kind: "offer.status"; offerId: string; status: OfferStatus }
  | { kind: "push"; to: string; template: PushTemplate; offerId?: string }
  | { kind: "schedule"; timer: TimerKind; at: string; offerId?: string; proofId?: string; round?: number }
  | { kind: "grade"; proofId: string }
  | { kind: "payout" }
  | { kind: "refund" }
  | { kind: "stats"; userId: string; delta: Partial<Record<StatKey, number>> }
  // The poster rated the worker: learn which skills the job proved (or didn't).
  | { kind: "learn" };

// Append-only history of a job. seq equals the job version the event produced.
export interface LedgerEvent {
  jobId: string;
  seq: number;
  type: JobEventType | "CREATED";
  from: JobState | null;
  to: JobState;
  actor: Actor;
  event: JobEvent | null;
  effects: Effect[];
  at: string;
  // Written by a process that runs effects itself (local dev); the deployed outbox skips it.
  inline: boolean;
}
