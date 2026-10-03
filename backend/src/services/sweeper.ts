// Backstop for anything lost in transit: a timer that never fired, an offer cascade that stalled,
// a payout or refund whose effect ended up in the dead-letter queue. Runs every minute. Everything it
// does goes through the same idempotent paths as the originals, so a sweep that overlaps a normal
// timer or effect is harmless.

import type { Deps } from "../deps.js";
import { rematchDelaySec } from "../domain/rules.js";
import type { Job } from "../domain/types.js";
import type { TimerPayload } from "../scheduler/index.js";
import { sendNextOffer } from "./matching.js";
import { runPayout, runRefund } from "./payments.js";
import { fireTimer } from "./timers.js";

// Leave fresh jobs to their normal effects; only step in once something is clearly overdue.
const GRACE_MS = 2 * 60_000;

function overdueTimers(deps: Deps, job: Job, now: number): TimerPayload[] {
  const rules = deps.config.rules;
  const timer = (kind: TimerPayload["timer"], atMs: number, extra: Partial<TimerPayload> = {}): TimerPayload[] =>
    now >= atMs ? [{ kind: "timer", jobId: job.jobId, timer: kind, at: new Date(atMs).toISOString(), ...extra }] : [];
  const due: TimerPayload[] = [];
  if (["FUNDED", "OFFERED", "ACCEPTED", "IN_PROGRESS"].includes(job.state)) due.push(...timer("deadline", Date.parse(job.deadline)));
  if (job.state === "OFFERED" && job.currentOffer) due.push(...timer("offer_expire", Date.parse(job.currentOffer.expiresAt), { offerId: job.currentOffer.offerId }));
  if (job.state === "IN_REVIEW" && job.review) due.push(...timer("review_window", Date.parse(job.review.windowEndsAt)));
  if (job.state === "SUBMITTED" && job.submittedAt) {
    due.push(...timer("grade_timeout", Date.parse(job.submittedAt) + rules.gradeTimeoutSec * 1000, { proofId: job.latestProofId }));
  }
  if (job.state === "DISPUTED" && job.dispute) due.push(...timer("dispute_timeout", Date.parse(job.dispute.openedAt) + rules.disputeWindowSec * 1000));
  if (job.state === "FUNDED" && job.exhaustedRound === job.matchRounds) {
    due.push(...timer("rematch", Date.parse(job.updatedAt) + rematchDelaySec(rules, job.matchRounds) * 1000 + GRACE_MS, { round: job.matchRounds }));
  }
  return due;
}

export async function sweep(deps: Deps): Promise<{ checked: number; actions: number }> {
  const now = deps.now().getTime();
  const jobs = await deps.store.listJobsNeedingAttention();
  let actions = 0;
  for (const job of jobs) {
    const stale = now - Date.parse(job.updatedAt) > GRACE_MS;
    try {
      for (const payload of overdueTimers(deps, job, now)) {
        await fireTimer(deps, payload);
        actions++;
      }
      if (!stale) continue;
      if (job.state === "FUNDED" && !job.currentOffer && job.exhaustedRound !== job.matchRounds) {
        await sendNextOffer(deps, job.jobId);
        actions++;
      }
      if (job.state === "RELEASED" && !job.payment.transferId) {
        await runPayout(deps, job.jobId);
        actions++;
      }
      if (job.state === "REFUNDED" && !job.payment.refundId) {
        await runRefund(deps, job.jobId);
        actions++;
      }
    } catch (error) {
      deps.log.error("Sweep failed for job", { jobId: job.jobId, error });
    }
  }
  if (actions > 0) deps.log.info("Sweep", { checked: jobs.length, actions });
  return { checked: jobs.length, actions };
}
