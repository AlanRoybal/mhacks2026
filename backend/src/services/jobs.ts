import type { Deps } from "../deps.js";
import type { JobEvent, LedgerEvent } from "../domain/events.js";
import { transition } from "../domain/jobMachine.js";
import type { Actor, Job } from "../domain/types.js";
import { notFound } from "../lib/errors.js";
import { VersionConflictError } from "../store/index.js";
import { runEffects } from "./effects.js";

const MAX_ATTEMPTS = 5;

export async function getJobOrThrow(deps: Deps, jobId: string): Promise<Job> {
  const job = await deps.store.getJob(jobId);
  if (!job) throw notFound("Job");
  return job;
}

// The only way a job changes state: read, run the state machine, commit job + ledger row atomically.
// If another request committed first, re-read and re-run; the machine then decides against the new state
// (for example, the second of two accepts gets "offer_not_current").
export async function applyEvent(deps: Deps, jobId: string, event: JobEvent, actor: Actor): Promise<Job> {
  for (let attempt = 1; ; attempt++) {
    const job = await getJobOrThrow(deps, jobId);
    const now = deps.now();
    const result = transition(job, event, { now, actor, rules: deps.config.rules });
    const next: Job = { ...job, ...result.patch, state: result.to, version: job.version + 1, updatedAt: now.toISOString() };
    const ledger: LedgerEvent = {
      jobId,
      seq: next.version,
      type: event.type,
      from: job.state,
      to: next.state,
      actor,
      event,
      effects: result.effects,
      at: now.toISOString(),
      inline: Boolean(deps.inlineEffects),
    };
    try {
      await deps.store.commitTransition(job.version, next, ledger);
    } catch (e) {
      if (e instanceof VersionConflictError && attempt < MAX_ATTEMPTS) continue;
      throw e;
    }
    deps.log.info("Job transition", { jobId, event: event.type, from: job.state, to: next.state, seq: next.version });
    dispatchEffects(deps, ledger);
    return next;
  }
}

export async function createJobRecord(deps: Deps, job: Job, actor: Actor): Promise<void> {
  const created: LedgerEvent = {
    jobId: job.jobId,
    seq: job.version,
    type: "CREATED",
    from: null,
    to: job.state,
    actor,
    event: null,
    effects: [],
    at: job.createdAt,
    inline: Boolean(deps.inlineEffects),
  };
  await deps.store.createJob(job, created);
}

// In stream mode the worker Lambda picks the ledger row up from the DynamoDB Stream instead.
function dispatchEffects(deps: Deps, ledger: LedgerEvent): void {
  if (!deps.inlineEffects || ledger.effects.length === 0) return;
  deps.inlineEffects.enqueue(`${ledger.jobId}#${ledger.seq}`, () => runEffects(deps, ledger));
}
