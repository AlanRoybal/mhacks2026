// Demo and debugging tools. Mounted only when DEMO_MODE=true or STAGE=local; on deployed stages every
// request also needs the x-demo-key header (see demoAccess in api/auth.ts).

import { Hono } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import type { Job } from "../../domain/types.js";
import { conflict, forbidden, notFound } from "../../lib/errors.js";
import { applyEvent, getJobOrThrow } from "../../services/jobs.js";
import { ineligibleReason, rerankCandidate } from "../../services/matching.js";
import { briefOf } from "../../services/postings.js";
import { fireTimer } from "../../services/timers.js";
import type { TimerPayload } from "../../scheduler/index.js";
import { VersionConflictError } from "../../store/index.js";
import { demoAccess, isAdmin } from "../auth.js";
import { parseBody, type AppEnv } from "../http.js";
import { jobWire, wireDate, WireContext } from "../wire.js";

const SYSTEM = { kind: "system" as const, source: "demo" };

// Moves the job's next due time to now, then fires that timer. Demo only: it edits the due field directly.
async function fastForward(deps: Deps, job: Job): Promise<TimerPayload | null> {
  const now = deps.now();
  const nowIso = now.toISOString();
  const rules = deps.config.rules;
  const next = structuredClone(job);
  let payload: TimerPayload | null = null;
  const timer = (kind: TimerPayload["timer"], extra: Partial<TimerPayload> = {}): TimerPayload => ({ kind: "timer", jobId: job.jobId, timer: kind, at: nowIso, ...extra });
  switch (job.state) {
    case "OFFERED":
      if (next.currentOffer) {
        next.currentOffer.expiresAt = nowIso;
        payload = timer("offer_expire", { offerId: next.currentOffer.offerId });
      }
      break;
    case "IN_REVIEW":
      if (next.review) {
        next.review.windowEndsAt = nowIso;
        payload = timer("review_window");
      }
      break;
    case "SUBMITTED":
      next.submittedAt = new Date(now.getTime() - rules.gradeTimeoutSec * 1000).toISOString();
      payload = timer("grade_timeout", { proofId: job.latestProofId });
      break;
    case "DISPUTED":
      if (next.dispute) {
        next.dispute.openedAt = new Date(now.getTime() - rules.disputeWindowSec * 1000).toISOString();
        payload = timer("dispute_timeout");
      }
      break;
    case "FUNDED":
    case "ACCEPTED":
    case "IN_PROGRESS":
      next.deadline = nowIso;
      payload = timer("deadline");
      break;
    default:
      return null;
  }
  if (!payload) return null;
  try {
    await deps.store.saveJob(job.version, { ...next, version: job.version + 1, updatedAt: nowIso });
  } catch (e) {
    if (e instanceof VersionConflictError) throw conflict("busy", "The job changed; try again");
    throw e;
  }
  await fireTimer(deps, payload);
  return payload;
}

// Demo tools act on jobs you are part of (or any job, for admins).
async function ownJob(deps: Deps, user: Parameters<typeof isAdmin>[1], jobId: string): Promise<Job> {
  const job = await getJobOrThrow(deps, jobId);
  if (job.posterId !== user.userId && job.workerId !== user.userId && !isAdmin(deps, user)) throw forbidden("Not your job");
  return job;
}

export function demoRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  app.use("*", async (c, next) => {
    if (!demoAccess(deps, c.req.header("x-demo-key"))) throw forbidden("Demo tools are disabled");
    await next();
  });
  const wire = async (jobId: string, viewer: Parameters<typeof jobWire>[2]) => jobWire(new WireContext(deps), await getJobOrThrow(deps, jobId), viewer);

  // Fund a draft without Stripe (switches it to the fake rail). For seed data and rehearsals.
  app.post("/jobs/:id/fund", async (c) => {
    const user = c.get("user");
    const job = await getJobOrThrow(deps, c.req.param("id"));
    if (job.posterId !== user.userId) throw forbidden("Only the poster can fund this job");
    if (job.state !== "DRAFT") throw conflict("already_funded", `The job is already ${job.state}`);
    await deps.store.saveJob(job.version, { ...job, rail: "fake", version: job.version + 1, updatedAt: deps.now().toISOString() });
    await applyEvent(deps, job.jobId, { type: "FUND_CONFIRMED", amountCents: job.totalCents }, SYSTEM);
    return c.json(await wire(job.jobId, user));
  });

  // Send a funded job straight to one person's phone, skipping matching (the judge's device).
  app.post("/offer", async (c) => {
    const body = await parseBody(c, z.object({ jobId: z.string(), userId: z.string().optional(), handle: z.string().optional() }));
    const workerId = body.userId ?? (body.handle ? await deps.store.kvGet<string>(`identity:demo:${body.handle}`) : null);
    if (!workerId) throw notFound("Worker");
    const job = await ownJob(deps, c.get("user"), body.jobId);
    if (job.state !== "FUNDED") throw conflict("invalid_transition", `The job must be FUNDED (it is ${job.state})`);
    const worker = await deps.store.getUser(workerId);
    if (!worker) throw notFound("Worker");
    // Ask the ranker for a real "why you" line, as a normal match would have.
    const [pick] = await deps.ai.rerank(briefOf(job), [rerankCandidate(worker, 0.9)]);
    const now = deps.now();
    const offerId = `${job.jobId}-r${job.matchRounds}-demo-${now.getTime()}`;
    const expiresAt = new Date(now.getTime() + deps.config.rules.offerTtlSec * 1000).toISOString();
    await deps.store.createOffers([
      {
        offerId,
        jobId: job.jobId,
        workerId,
        round: job.matchRounds,
        rank: 0,
        status: "queued",
        fit: Math.round(pick?.fit ?? 90),
        why: pick?.why ?? "Your twin picked this one for you",
        estMinutes: job.estMinutes,
        hourlyCents: Math.round((job.bountyCents * 60) / Math.max(job.estMinutes, 1)),
        score: 1,
        createdAt: now.toISOString(),
        expiresAt,
      },
    ]);
    await applyEvent(deps, job.jobId, { type: "OFFER_SENT", offerId, workerId, expiresAt }, SYSTEM);
    return c.json({ offerId, expiresAt: wireDate(expiresAt) });
  });

  // Jump to the job's next deadline: offer expiry, review window, grading timeout, dispute window or deadline.
  app.post("/jobs/:id/fast-forward", async (c) => {
    const job = await ownJob(deps, c.get("user"), c.req.param("id"));
    const fired = await fastForward(deps, job);
    if (!fired) throw conflict("nothing_to_do", `Nothing to fast-forward while the job is ${job.state}`);
    if (deps.inlineEffects) await deps.inlineEffects.drain();
    return c.json({ fired: fired.timer, job: await wire(job.jobId, c.get("user")).catch(() => null) });
  });

  // Why did (or didn't) each person get this job? Eligibility for every user.
  app.get("/jobs/:id/explain", async (c) => {
    const job = await ownJob(deps, c.get("user"), c.req.param("id"));
    const now = deps.now();
    const users = await deps.store.listUsers();
    const offers = await deps.store.listOffersForJob(job.jobId);
    return c.json({
      state: job.state,
      round: job.matchRounds,
      offers: offers.map((o) => ({ offerId: o.offerId, workerId: o.workerId, round: o.round, rank: o.rank, status: o.status, fit: o.fit, why: o.why })),
      users: users.map((u) => ({ userId: u.userId, name: u.displayName, eligible: !ineligibleReason(job, u, now), reason: ineligibleReason(job, u, now) })),
    });
  });

  return app;
}
