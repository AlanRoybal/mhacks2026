import type { Deps } from "../deps.js";
import type { JobEvent } from "../domain/events.js";
import { TransitionError } from "../domain/jobMachine.js";
import { AppError } from "../lib/errors.js";
import type { TimerPayload } from "../scheduler/scheduler.js";
import { applyEvent } from "./jobs.js";

function eventFor(p: TimerPayload): JobEvent {
  switch (p.timer) {
    case "offer_expire":
      return { type: "OFFER_EXPIRED", offerId: p.offerId ?? "" };
    case "review_window":
      return { type: "REVIEW_WINDOW_EXPIRED" };
    case "deadline":
      return { type: "DEADLINE_PASSED" };
    case "rematch":
      return { type: "REMATCH", round: p.round ?? -1 };
    case "grade_timeout":
      return { type: "GRADE_TIMEOUT", proofId: p.proofId ?? "" };
    case "dispute_timeout":
      return { type: "DISPUTE_TIMEOUT" };
  }
}

// A timer only proposes an event. If the job has moved on, the state machine rejects it and we drop it.
export async function fireTimer(deps: Deps, p: TimerPayload): Promise<void> {
  try {
    await applyEvent(deps, p.jobId, eventFor(p), { kind: "system", source: `timer:${p.timer}` });
  } catch (e) {
    if (e instanceof TransitionError) {
      // Fired before its time (clock skew): try again when it is actually due.
      if (e.code === "too_early" && Date.parse(p.at) > deps.now().getTime()) {
        await deps.scheduler.schedule(`${p.timer}-${p.jobId}-retry-${Date.parse(p.at)}`, p);
        return;
      }
      deps.log.info("Timer no longer applies", { jobId: p.jobId, timer: p.timer, reason: e.code });
      return;
    }
    if (e instanceof AppError && e.status === 404) return;
    throw e;
  }
}
