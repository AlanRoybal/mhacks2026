// Gathers the inputs for domain/risk.ts from the store: each worker's history, each poster's disputes,
// every open escrow. Used by matching (exposure limits), the job view (risk shown to the poster) and
// the admin risk report (the platform's reserve).

import type { Deps } from "../deps.js";
import {
  disputeProbability,
  expectedLoss,
  exposureLimitCents,
  simulatePortfolio,
  trustScore,
  type ExpectedLoss,
  type Outcome,
  type RiskRail,
  type TrustScore,
} from "../domain/risk.js";
import type { Job, User } from "../domain/types.js";

const OPEN = new Set(["ACCEPTED", "IN_PROGRESS", "SUBMITTED", "IN_REVIEW", "DISPUTED"]);
const ESCROWED = new Set(["FUNDED", "OFFERED", ...OPEN]);
// A worker who failed a job they'd started (deadline refund, or rejected after the AI failed it).
const workerFailed = (job: Job) => job.state === "REFUNDED" && Boolean(job.startedAt) && job.resolution?.outcome !== "release";

export const railOf = (job: Job): RiskRail => (job.rail === "usdc" ? "usdc" : "card");

export function workerHistory(jobs: Job[], user: User, now: Date): Outcome[] {
  const outcomes: Outcome[] = [];
  for (const job of jobs) {
    if (job.workerId !== user.userId) continue;
    const at = job.updatedAt;
    if (job.state === "RELEASED") {
      outcomes.push({ at, counterpartyId: job.posterId, amountCents: job.bountyCents, result: "completed", stars: job.ratings.byPoster?.stars });
    } else if (workerFailed(job)) {
      outcomes.push({ at, counterpartyId: job.posterId, amountCents: job.bountyCents, result: "failed" });
    }
  }
  // Withdrawals leave the job, so only the count survives; each is its own counterparty, dated now.
  for (let i = 0; i < user.stats.withdrawals; i++) {
    outcomes.push({ at: now.toISOString(), counterpartyId: `withdrawal-${i}`, amountCents: 2000, result: "withdrew" });
  }
  return outcomes;
}

export async function workerTrust(deps: Deps, user: User): Promise<{ trust: TrustScore; limitCents: number; openCents: number }> {
  const now = deps.now();
  const jobs = await deps.store.listJobsByWorker(user.userId);
  const trust = trustScore(workerHistory(jobs, user, now), now);
  const openCents = jobs.filter((j) => j.workerId === user.userId && OPEN.has(j.state)).reduce((sum, j) => sum + j.bountyCents, 0);
  return { trust, limitCents: exposureLimitCents(trust), openCents };
}

// Whether taking this job keeps the worker inside their exposure limit.
export async function withinExposureLimit(deps: Deps, user: User, job: Job): Promise<boolean> {
  const { limitCents, openCents } = await workerTrust(deps, user);
  return openCents + job.bountyCents <= limitCents;
}

export async function posterDisputeRisk(deps: Deps, posterId: string): Promise<number> {
  const jobs = await deps.store.listJobsByPoster(posterId);
  const finished = jobs.filter((j) => j.state === "RELEASED" || j.state === "REFUNDED");
  // Disputes the poster opened that an admin (or the timeout) settled in the worker's favor.
  const lost = finished.filter((j) => j.dispute?.openedBy === "poster" && j.state === "RELEASED").length;
  return disputeProbability(lost, finished.length);
}

export interface JobRisk extends ExpectedLoss {
  rail: RiskRail;
  worker: { trust: number; lower: number; ratedJobs: number } | null;
  posterDispute: number;
}

// The risk of one escrow. Before a worker is assigned, the worker side uses the prior (a new worker).
export async function jobRisk(deps: Deps, job: Job): Promise<JobRisk> {
  const worker = job.workerId ? await deps.store.getUser(job.workerId) : null;
  const trust = worker ? (await workerTrust(deps, worker)).trust : trustScore([], deps.now());
  const posterDispute = await posterDisputeRisk(deps, job.posterId);
  const rail = railOf(job);
  const loss = expectedLoss({ amountCents: job.bountyCents, rail, workerPd: trust.pd, posterDispute });
  return {
    ...loss,
    rail,
    worker: worker ? { trust: trust.mean, lower: trust.lower, ratedJobs: Math.round(trust.effectiveJobs * 10) / 10 } : null,
    posterDispute,
  };
}

export interface RiskReport {
  asOf: string;
  escrows: number;
  exposureCents: number;
  portfolio: ReturnType<typeof simulatePortfolio>;
  // Share of all escrow held by the single biggest worker: concentration risk.
  concentration: { workerId: string; share: number } | null;
  // Pairs of accounts trading many top-rated jobs with each other: a possible rating ring.
  flags: { kind: "rating_ring"; posterId: string; workerId: string; jobs: number }[];
  riskiest: { jobId: string; title: string; tier: string; expectedLossCents: number; exposureCents: number }[];
}

export async function riskReport(deps: Deps): Promise<RiskReport> {
  const now = deps.now();
  const open = (await deps.store.listJobsNeedingAttention()).filter((j) => ESCROWED.has(j.state));
  const risks = await Promise.all(open.map(async (job) => ({ job, risk: await jobRisk(deps, job) })));
  const exposureCents = open.reduce((sum, j) => sum + j.bountyCents, 0);

  const byWorker = new Map<string, number>();
  for (const job of open) if (job.workerId) byWorker.set(job.workerId, (byWorker.get(job.workerId) ?? 0) + job.bountyCents);
  const top = [...byWorker.entries()].sort((a, b) => b[1] - a[1])[0];

  // Rating rings: 3+ five-star jobs between the same pair within 30 days.
  const flags: RiskReport["flags"] = [];
  const pairs = new Map<string, { posterId: string; workerId: string; jobs: number }>();
  for (const user of await deps.store.listUsers()) {
    for (const job of await deps.store.listJobsByWorker(user.userId)) {
      if (job.state !== "RELEASED" || job.ratings.byPoster?.stars !== 5) continue;
      if (now.getTime() - Date.parse(job.updatedAt) > 30 * 24 * 3600_000) continue;
      const key = `${job.posterId}|${user.userId}`;
      const pair = pairs.get(key) ?? { posterId: job.posterId, workerId: user.userId, jobs: 0 };
      pair.jobs++;
      pairs.set(key, pair);
    }
  }
  for (const pair of pairs.values()) if (pair.jobs >= 3) flags.push({ kind: "rating_ring", ...pair });

  return {
    asOf: now.toISOString(),
    escrows: open.length,
    exposureCents,
    portfolio: simulatePortfolio(risks.map((r) => r.risk.events)),
    concentration: top && exposureCents > 0 ? { workerId: top[0], share: Math.round((top[1] / exposureCents) * 1000) / 1000 } : null,
    flags,
    riskiest: risks
      .sort((a, b) => b.risk.expectedLossCents - a.risk.expectedLossCents)
      .slice(0, 5)
      .map(({ job, risk }) => ({ jobId: job.jobId, title: job.title, tier: risk.tier, expectedLossCents: risk.expectedLossCents, exposureCents: risk.exposureCents })),
  };
}
