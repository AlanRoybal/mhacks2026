import type { TimerKind } from "../domain/events.js";

// What a timer delivers back to the worker when it fires.
export interface TimerPayload {
  kind: "timer";
  jobId: string;
  timer: TimerKind;
  // When it was meant to fire.
  at: string;
  offerId?: string;
  round?: number;
}

export interface Scheduler {
  // Idempotent: scheduling the same name twice keeps the first.
  schedule(name: string, payload: TimerPayload): Promise<void>;
}

export type TimerHandler = (payload: TimerPayload) => Promise<void>;

// EventBridge schedule names: max 64 chars of [0-9a-zA-Z-_.].
export function timerName(payload: TimerPayload, seq: number): string {
  return `${payload.timer}-${payload.jobId}-${seq}`.replace(/[^0-9a-zA-Z\-_.]/g, "_").slice(0, 64);
}
