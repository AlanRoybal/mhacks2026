// Live job sessions (SpacetimeDB) in the product: opened when the worker starts, fed by the phone's
// location pings and proof progress, mirrored from every job transition, read back to verify time on
// site, and pushed to both people's Live Activities whenever something changes.

import { wireDate } from "../api/wire.js";
import type { Deps } from "../deps.js";
import type { LedgerEvent } from "../domain/events.js";
import { minOnSiteSec, type Rules } from "../domain/rules.js";
import type { Job, JobState, User } from "../domain/types.js";
import { ACTIVE_PHASES, onSiteSeconds, type LiveEvent, type LivePhase, type LiveSession } from "../live/index.js";

export type LiveRole = "worker" | "poster";

interface ActivityToken {
  userId: string;
  role: LiveRole;
  token: string;
  env: "sandbox" | "production";
}

const tokensKey = (jobId: string) => `liveact:${jobId}`;
const TERMINAL: ReadonlySet<LivePhase> = new Set(["paid", "refunded", "closed"]);

// What each job state means for the live session.
function phaseFor(job: Job): { phase: LivePhase; detail: string } | null {
  const states: Partial<Record<JobState, { phase: LivePhase; detail: string }>> = {
    SUBMITTED: { phase: "verifying", detail: "Proof submitted. The AI is checking it." },
    IN_REVIEW: { phase: "in_review", detail: "Waiting on the poster's review" },
    DISPUTED: { phase: "in_review", detail: "The poster disputed an item" },
    RELEASED: { phase: "paid", detail: "Paid" },
    REFUNDED: { phase: "refunded", detail: "Refunded" },
    FUNDED: { phase: "closed", detail: "The worker withdrew" },
    // Proof failed and the worker is retrying.
    IN_PROGRESS: { phase: job.remote ? "started" : "away", detail: "Proof needs another try" },
  };
  return states[job.state] ?? null;
}

// Content for the app's BountyLiveAttributes.ContentState (ActivityKit decodes it, so no ISO dates):
// timerStartEpoch is "now minus time on site" in Unix seconds while on site, so the widget's ticking
// timer shows the total including earlier stretches.
export function liveContent(session: LiveSession, job: Job, rules: Rules, now: Date) {
  const seconds = onSiteSeconds(session, now);
  const onSite = Boolean(session.onSiteSince) && ACTIVE_PHASES.has(session.phase);
  return {
    phase: session.phase,
    onSiteSeconds: seconds,
    timerStartEpoch: onSite ? Math.floor(now.getTime() / 1000) - seconds : null,
    itemsDone: session.itemsDone,
    itemsTotal: session.itemsTotal,
    minOnSiteSeconds: job.remote ? 0 : minOnSiteSec(rules, job.estMinutes),
    leftSiteCount: session.leftSiteCount,
  };
}

export function liveView(deps: Deps, session: LiveSession, events: LiveEvent[], job: Job) {
  const now = deps.now();
  return {
    provider: deps.live.name,
    ...liveContent(session, job, deps.config.rules, now),
    // Second precision, as the app's decoder reads dates.
    startedAt: wireDate(session.startedAt),
    lastPingAt: wireDate(session.lastPingAt),
    lastDistanceM: session.lastDistanceM === undefined ? null : Math.round(session.lastDistanceM),
    signalLostCount: session.signalLostCount,
    radiusM: session.radiusM,
    events: events.slice(-20).reverse().map((e) => ({ ...e, at: wireDate(e.at) })),
  };
}

async function pushActivities(deps: Deps, job: Job, session: LiveSession, alert?: { title: string; body: string }): Promise<void> {
  const tokens = (await deps.store.kvGet<ActivityToken[]>(tokensKey(job.jobId))) ?? [];
  if (tokens.length === 0) return;
  const now = deps.now();
  const ended = TERMINAL.has(session.phase);
  const nowSec = Math.floor(now.getTime() / 1000);
  const dead: string[] = [];
  await Promise.all(
    tokens.map(async (t) => {
      const result = await deps.push.liveActivity(
        {
          token: t.token,
          env: t.env,
          event: ended ? "end" : "update",
          contentState: liveContent(session, job, deps.config.rules, now),
          // Shown as stale if no update arrives for 3 minutes (the phone stopped pinging).
          staleDate: ended ? undefined : nowSec + 180,
          dismissalDate: ended ? nowSec + 15 * 60 : undefined,
          alert,
        },
        now,
      );
      if (result === "dead") dead.push(t.token);
    }),
  );
  if (dead.length > 0) await deps.store.kvPut(tokensKey(job.jobId), tokens.filter((t) => !dead.includes(t.token)));
}

// Called for every committed transition (services/effects.ts). START opens the session; everything after
// is mirrored, so the session's phase and the Live Activities follow the job.
export async function syncLive(deps: Deps, ledger: LedgerEvent): Promise<void> {
  if (ledger.from === ledger.to) return;
  const job = await deps.store.getJob(ledger.jobId);
  if (!job) return;
  if (ledger.type === "START" && job.workerId) {
    const startCheck = job.startCheck;
    await deps.live.open({
      jobId: job.jobId,
      workerId: job.workerId,
      posterId: job.posterId,
      title: job.title,
      remote: job.remote,
      lat: job.location?.lat ?? 0,
      lng: job.location?.lng ?? 0,
      radiusM: deps.config.rules.checkInRadiusM,
      itemsTotal: job.checklist.filter((i) => i.evidenceType !== "CHECK_IN").length,
      startDistanceM: startCheck?.distanceM ?? 0,
      startAccuracyM: startCheck?.accuracyM ?? 0,
    });
  } else {
    const next = phaseFor(job);
    if (!next) return;
    await deps.live.setPhase(job.jobId, next.phase, next.detail);
  }
  const session = await deps.live.get(job.jobId);
  if (session) await pushActivities(deps, job, session);
}

// A location fix from the worker's phone. SpacetimeDB decides on or off site; we push only real changes.
export async function recordPing(deps: Deps, job: Job, lat: number, lng: number, accuracyM: number): Promise<LiveSession | null> {
  const before = await deps.live.get(job.jobId);
  await deps.live.ping(job.jobId, lat, lng, accuracyM);
  const after = await deps.live.get(job.jobId);
  if (after && before && (after.phase !== before.phase || after.leftSiteCount !== before.leftSiteCount)) {
    const alert = after.phase === "away" ? { title: job.title, body: "Left the job site. The on-site timer is paused." } : undefined;
    await pushActivities(deps, job, after, alert);
  }
  return after;
}

export async function recordProgress(deps: Deps, job: Job, itemsDone: number): Promise<LiveSession | null> {
  const before = await deps.live.get(job.jobId);
  await deps.live.progress(job.jobId, itemsDone);
  const after = await deps.live.get(job.jobId);
  if (after && before && after.itemsDone !== before.itemsDone) await pushActivities(deps, job, after);
  return after;
}

export async function registerActivity(deps: Deps, job: Job, user: User, role: LiveRole, token: string, env: "sandbox" | "production"): Promise<void> {
  const key = tokensKey(job.jobId);
  const tokens = ((await deps.store.kvGet<ActivityToken[]>(key)) ?? []).filter((t) => !(t.userId === user.userId && t.role === role));
  tokens.push({ userId: user.userId, role, token, env });
  await deps.store.kvPut(key, tokens);
  // Bring the new activity up to date right away.
  const session = await deps.live.get(job.jobId);
  if (session) await pushActivities(deps, job, session);
}
