// Matching a funded job to workers, and the one-at-a-time offer cascade (US-21..26).
//
//   hard filters  -> eligible workers (ready, pay, category, work type, radius, free time)
//   pre-rank      -> 0.6 * skill similarity + 0.2 * reliability + 0.2 * proximity
//   AI re-rank    -> top 8 get a fit score and a "why you" line; low fits are dropped
//   cascade       -> offers go out in rank order; decline/expiry moves to the next (state machine)

import { clamp, cosine, type RerankCandidate } from "../ai/index.js";
import type { Deps } from "../deps.js";
import { hasFreeWindow, isQuietTime } from "../domain/availability.js";
import { haversineKm, travelMinutes } from "../domain/geo.js";
import { hourlyCents } from "../domain/money.js";
import type { Actor, Job, Offer, User } from "../domain/types.js";
import { applyEvent } from "./jobs.js";
import { briefOf } from "./postings.js";
import { activeSkills, readiness, twinDocument } from "./twin.js";
import { averageStars } from "./trackRecord.js";
import { reliability } from "./users.js";

const SYSTEM: Actor = { kind: "system", source: "matching" };
const RERANK_POOL = 8;
const MIN_FIT = 40;
const SOURCE_LABEL = { linkedin: "LinkedIn", resume: "résumé", email: "email", user: "self-reported", rating: "rated jobs" } as const;

const jobDocument = (job: Job) => `${job.title}\n${job.category.toLowerCase().replace("_", " ")}\n${job.description}`;

interface Candidate {
  user: User;
  distanceKm?: number;
  score: number;
}

// Why a worker is not eligible right now, or null if they are. Useful when debugging "why no offer?".
export function ineligibleReason(job: Job, user: User, now: Date): string | null {
  if (user.userId === job.posterId) return "poster";
  if (user.seed) return "seed user";
  if (job.excludedWorkerIds.includes(user.userId)) return "already declined or withdrew";
  const ready = readiness(user, { payoutsRequired: job.rail === "stripe" });
  if (!ready.ready) return `not ready: ${ready.missing.join(", ")}`;
  if (job.bountyCents < user.prefs.minPayCents) return "below minimum pay";
  if (user.prefs.blockedCategories.includes(job.category)) return "blocked category";
  if (job.remote) {
    if (!user.prefs.remoteOk) return "no remote work";
  } else {
    if (!user.prefs.inPersonOk) return "no in-person work";
    if (!user.prefs.base || !job.location) return "no location";
    const km = haversineKm(user.prefs.base, job.location);
    if (km > Math.min(job.radiusKm, user.prefs.maxRadiusKm)) return "too far";
  }
  const travel = job.remote || !user.prefs.base || !job.location ? 0 : travelMinutes(haversineKm(user.prefs.base, job.location));
  if (!hasFreeWindow(user.availability, now, new Date(job.deadline), job.estMinutes + travel)) return "busy before the deadline";
  return null;
}

// How a worker is described to the ranker: top skills with where each came from.
export function rerankCandidate(user: User, score: number, distanceKm?: number): RerankCandidate {
  return {
    workerId: user.userId,
    summary: user.twin.summary,
    skills: activeSkills(user.twin)
      .slice(0, 8)
      .map((s) => {
        const from = [...new Set(s.sources.map((src) => SOURCE_LABEL[src.kind]))].join(", ");
        const record = s.record?.jobs ? `; ${s.record.jobs} rated job${s.record.jobs === 1 ? "" : "s"}, avg ${averageStars(s)}\u2605` : "";
        return `${s.name} (${from}${record})`;
      }),
    distanceKm,
    reliability: reliability(user.stats).score,
    score,
  };
}

async function rankCandidates(deps: Deps, job: Job): Promise<Offer[]> {
  const now = deps.now();
  const users = await deps.store.listUsers();
  const jobVector = await deps.embedder.embed(jobDocument(job));
  const candidates: Candidate[] = [];
  for (const user of users) {
    if (ineligibleReason(job, user, now)) continue;
    const distanceKm = job.remote || !user.prefs.base || !job.location ? undefined : haversineKm(user.prefs.base, job.location);
    const twinVector = user.twin.embedding && user.twin.embeddingModel === deps.embedder.model ? user.twin.embedding : await deps.embedder.embed(twinDocument(user));
    const similarity = Math.max(0, cosine(jobVector, twinVector));
    const proximity = distanceKm === undefined ? 1 : 1 - distanceKm / Math.max(job.radiusKm, 0.1);
    candidates.push({ user, distanceKm, score: 0.6 * similarity + 0.2 * reliability(user.stats).score + 0.2 * proximity });
  }
  candidates.sort((a, b) => b.score - a.score);
  const pool = candidates.slice(0, RERANK_POOL);
  if (pool.length === 0) return [];

  const byId = new Map(pool.map((c) => [c.user.userId, c]));
  const input = pool.map((c) => rerankCandidate(c.user, c.score, c.distanceKm));
  const picks = await deps.ai.rerank(briefOf(job), input);

  const seen = new Set<string>();
  const offers: Offer[] = [];
  for (const pick of picks) {
    const candidate = byId.get(pick.workerId);
    if (!candidate || seen.has(pick.workerId) || pick.fit < MIN_FIT) continue;
    seen.add(pick.workerId);
    const rank = offers.length + 1;
    const estMinutes = Math.round(clamp(pick.estMinutes, 5, 600));
    offers.push({
      offerId: `${job.jobId}-r${job.matchRounds}-${rank}`,
      jobId: job.jobId,
      workerId: pick.workerId,
      round: job.matchRounds,
      rank,
      status: "queued",
      fit: Math.round(clamp(pick.fit, 0, 100)),
      why: pick.why.trim().slice(0, 120),
      estMinutes,
      hourlyCents: hourlyCents(job.bountyCents, estMinutes),
      distanceKm: candidate.distanceKm,
      travelMinutes: candidate.distanceKm === undefined ? undefined : travelMinutes(candidate.distanceKm),
      score: Math.round(candidate.score * 1000) / 1000,
      createdAt: now.toISOString(),
    });
  }
  deps.log.info("Matched job", { jobId: job.jobId, round: job.matchRounds, eligible: candidates.length, offers: offers.length });
  return offers;
}

// The "match" effect. Safe to repeat: a round that already has offers is not ranked again.
export async function runMatch(deps: Deps, jobId: string): Promise<void> {
  const job = await deps.store.getJob(jobId);
  if (!job || job.state !== "FUNDED") return;
  let offers = (await deps.store.listOffersForJob(jobId)).filter((o) => o.round === job.matchRounds);
  if (offers.length === 0) {
    offers = await rankCandidates(deps, job);
    await deps.store.createOffers(offers);
  }
  // Pass the offers along: the byJob index is eventually consistent and may not show them yet.
  await sendNextOffer(deps, jobId, offers);
}

// The "offer.next" effect: offer the job to the best queued worker who can take it right now.
export async function sendNextOffer(deps: Deps, jobId: string, known?: Offer[]): Promise<void> {
  const job = await deps.store.getJob(jobId);
  if (!job || job.state !== "FUNDED") return;
  const now = deps.now();
  if (now.getTime() + job.estMinutes * 60_000 > Date.parse(job.deadline)) return; // the deadline timer refunds it
  const queued = (known ?? (await deps.store.listOffersForJob(jobId))).filter(
    (o) => o.round === job.matchRounds && o.status === "queued" && !job.excludedWorkerIds.includes(o.workerId),
  );
  for (const offer of queued) {
    const worker = await deps.store.getUser(offer.workerId);
    // Skip people who became ineligible or are in quiet hours; they stay queued for a later pass.
    if (!worker || ineligibleReason(job, worker, now) || isQuietTime(worker.prefs, now)) continue;
    const expiresAt = new Date(now.getTime() + deps.config.rules.offerTtlSec * 1000).toISOString();
    await deps.store.updateOffer(offer.offerId, { expiresAt });
    await applyEvent(deps, jobId, { type: "OFFER_SENT", offerId: offer.offerId, workerId: offer.workerId, expiresAt }, SYSTEM);
    return;
  }
  await applyEvent(deps, jobId, { type: "CANDIDATES_EXHAUSTED", round: job.matchRounds }, SYSTEM);
}
