// Runs the side effects a transition asked for. Called after the commit, either in-process
// (inline mode) or by the worker Lambda from the ledger stream. A record may be processed more
// than once, so every effect must be idempotent or harmless when repeated.

import type { Deps } from "../deps.js";
import type { Effect, LedgerEvent } from "../domain/events.js";
import { TransitionError } from "../domain/jobMachine.js";
import { bumpStats } from "./users.js";

export async function runEffects(deps: Deps, ledger: LedgerEvent): Promise<void> {
  const failures: unknown[] = [];
  for (const effect of ledger.effects) {
    try {
      await runEffect(deps, ledger, effect);
    } catch (error) {
      // The job moved on (e.g. someone accepted while we were sending the next offer). Nothing to do.
      if (error instanceof TransitionError) {
        deps.log.info("Effect no longer applies", { jobId: ledger.jobId, seq: ledger.seq, effect: effect.kind, reason: error.code });
        continue;
      }
      deps.log.error("Effect failed", { jobId: ledger.jobId, seq: ledger.seq, effect: effect.kind, error });
      failures.push(error);
    }
  }
  // Throwing makes the stream retry the whole record.
  if (failures.length > 0) throw new AggregateError(failures, `${failures.length} effect(s) failed for ${ledger.jobId}#${ledger.seq}`);
}

async function runEffect(deps: Deps, ledger: LedgerEvent, effect: Effect): Promise<void> {
  switch (effect.kind) {
    case "offer.status":
      await deps.store.updateOffer(effect.offerId, {
        status: effect.status,
        ...(effect.status === "sent" ? { sentAt: ledger.at } : { respondedAt: ledger.at }),
      });
      return;
    case "stats":
      await bumpStats(deps, effect.userId, effect.delta);
      return;
    case "match":
    case "offer.next":
    case "push":
    case "schedule":
    case "grade":
    case "payout":
    case "refund":
      deps.log.warn("Effect has no handler yet", { jobId: ledger.jobId, effect: effect.kind });
      return;
  }
}
