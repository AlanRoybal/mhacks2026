// Bounty's live layer: every in-progress job is a session in SpacetimeDB. The worker's location pings,
// on-site time, "left the site" detection, proof progress and the job's live phase are all decided here,
// inside transactional reducers, so there's one authoritative clock and one geofence for every job.
//
// The Bounty backend is the only writer (the identity that claimed the database, checked on every reducer), and it
// reads sessions back over SQL to verify proof (minimum time on site, whether the worker left) and to drive
// the Live Activities on both people's phones. A scheduled reducer notices when pings stop.

import { schema, table, t, SenderError, type InferSchema, type ReducerCtx } from 'spacetimedb/server';
import { ScheduleAt, Timestamp } from 'spacetimedb';

// A ping older than this means the phone stopped reporting (app closed, no signal).
const STALE_MICROS = 90_000_000n;
// How often the signal checker runs.
const CHECK_EVERY_MICROS = 30_000_000n;

const config = table(
  { name: 'config' },
  {
    key: t.string().primaryKey(),
    owner: t.identity(),
  }
);

const jobSession = table(
  { name: 'job_session' },
  {
    jobId: t.string().primaryKey(),
    workerId: t.string(),
    posterId: t.string(),
    title: t.string(),
    remote: t.bool(),
    lat: t.f64(),
    lng: t.f64(),
    // The geofence: within this many meters of the job counts as on site.
    radiusM: t.f64(),
    // started | on_site | away | signal_lost | submitted | verifying | in_review | paid | refunded | closed
    phase: t.string(),
    startedAt: t.timestamp(),
    // The current on-site stretch, if the worker is on site right now.
    onSiteSince: t.option(t.timestamp()),
    // Finished on-site stretches, added up.
    onSiteMicros: t.u64(),
    lastPingAt: t.option(t.timestamp()),
    lastDistanceM: t.option(t.f64()),
    lastAccuracyM: t.option(t.f64()),
    pings: t.u32(),
    leftSiteCount: t.u32(),
    signalLostCount: t.u32(),
    itemsTotal: t.u32(),
    itemsDone: t.u32(),
    updatedAt: t.timestamp(),
  }
);

const sessionEvent = table(
  { name: 'session_event' },
  {
    id: t.u64().primaryKey().autoInc(),
    jobId: t.string().index('btree'),
    at: t.timestamp(),
    // arrived | left | signal_lost | progress | phase
    kind: t.string(),
    detail: t.string(),
  }
);

const signalCheck = table(
  { name: 'signal_check' },
  {
    scheduledId: t.u64().primaryKey().autoInc(),
    scheduledAt: t.scheduleAt(),
  }
);

const spacetimedb = schema({ config, jobSession, sessionEvent, signalCheck });
export default spacetimedb;

type Ctx = ReducerCtx<InferSchema<typeof spacetimedb>>;
type Session = NonNullable<ReturnType<Ctx['db']['jobSession']['jobId']['find']>>;

const ACTIVE = new Set(['started', 'on_site', 'away', 'signal_lost']);

function requireOwner(ctx: Ctx): void {
  const row = ctx.db.config.key.find('owner');
  if (!row || !row.owner.equals(ctx.sender)) throw new SenderError('Only the Bounty backend can write sessions');
}

function micros(ts: Timestamp): bigint {
  return ts.microsSinceUnixEpoch;
}

function haversineM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const rad = (d: number) => (d * Math.PI) / 180;
  const a = Math.sin(rad(lat2 - lat1) / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lng2 - lng1) / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(a)));
}

function log(ctx: Ctx, jobId: string, kind: string, detail: string): void {
  ctx.db.sessionEvent.insert({ id: 0n, jobId, at: ctx.timestamp, kind, detail });
}

// Ends the current on-site stretch at `at`, crediting the time up to then.
function closeStretch(session: Session, at: Timestamp): Session {
  if (!session.onSiteSince) return session;
  const credited = micros(at) > micros(session.onSiteSince) ? micros(at) - micros(session.onSiteSince) : 0n;
  return { ...session, onSiteMicros: session.onSiteMicros + credited, onSiteSince: undefined };
}

// Before anything else: if the phone went quiet, the stretch ends at its last ping, not now.
function settleStaleness(ctx: Ctx, session: Session): Session {
  if (!session.onSiteSince || !session.lastPingAt) return session;
  if (micros(ctx.timestamp) - micros(session.lastPingAt) <= STALE_MICROS) return session;
  log(ctx, session.jobId, 'signal_lost', 'Location stopped updating; on-site time paused at the last check');
  return { ...closeStretch(session, session.lastPingAt), phase: 'signal_lost', signalLostCount: session.signalLostCount + 1 };
}

export const init = spacetimedb.init((ctx) => {
  ctx.db.signalCheck.insert({ scheduledId: 0n, scheduledAt: ScheduleAt.interval(CHECK_EVERY_MICROS) });
});

// The Bounty backend claims the database right after it's published; from then on only its identity
// can write. Calling it again with the same identity is a no-op.
export const claimBackend = spacetimedb.reducer((ctx) => {
  const row = ctx.db.config.key.find('owner');
  if (!row) {
    ctx.db.config.insert({ key: 'owner', owner: ctx.sender });
    return;
  }
  if (!row.owner.equals(ctx.sender)) throw new SenderError('This database already belongs to another backend');
});

// The worker tapped Start and the backend accepted their location. In-person jobs begin on site.
export const openSession = spacetimedb.reducer(
  {
    jobId: t.string(),
    workerId: t.string(),
    posterId: t.string(),
    title: t.string(),
    remote: t.bool(),
    lat: t.f64(),
    lng: t.f64(),
    radiusM: t.f64(),
    itemsTotal: t.u32(),
    startDistanceM: t.f64(),
    startAccuracyM: t.f64(),
  },
  (ctx, args) => {
    requireOwner(ctx);
    const existing = ctx.db.jobSession.jobId.find(args.jobId);
    if (existing) ctx.db.jobSession.jobId.delete(args.jobId);
    ctx.db.jobSession.insert({
      jobId: args.jobId,
      workerId: args.workerId,
      posterId: args.posterId,
      title: args.title,
      remote: args.remote,
      lat: args.lat,
      lng: args.lng,
      radiusM: args.radiusM,
      phase: args.remote ? 'started' : 'on_site',
      startedAt: ctx.timestamp,
      onSiteSince: args.remote ? undefined : ctx.timestamp,
      onSiteMicros: 0n,
      lastPingAt: args.remote ? undefined : ctx.timestamp,
      lastDistanceM: args.remote ? undefined : args.startDistanceM,
      lastAccuracyM: args.remote ? undefined : args.startAccuracyM,
      pings: args.remote ? 0 : 1,
      leftSiteCount: 0,
      signalLostCount: 0,
      itemsTotal: args.itemsTotal,
      itemsDone: 0,
      updatedAt: ctx.timestamp,
    });
    log(ctx, args.jobId, args.remote ? 'phase' : 'arrived', args.remote ? 'Started' : `Started on site, ${Math.round(args.startDistanceM)} m from the address`);
  }
);

// A location fix from the worker's phone while the job is open. The geofence and the clock are decided
// here: inside the radius starts or continues an on-site stretch, outside ends it.
export const ping = spacetimedb.reducer(
  { jobId: t.string(), lat: t.f64(), lng: t.f64(), accuracyM: t.f64() },
  (ctx, { jobId, lat, lng, accuracyM }) => {
    requireOwner(ctx);
    let session = ctx.db.jobSession.jobId.find(jobId);
    if (!session || session.remote || !ACTIVE.has(session.phase)) return;
    session = settleStaleness(ctx, session);
    const distance = haversineM(lat, lng, session.lat, session.lng);
    let next: Session = { ...session, lastPingAt: ctx.timestamp, lastDistanceM: distance, lastAccuracyM: accuracyM, pings: session.pings + 1, updatedAt: ctx.timestamp };
    // A fix too vague to place the worker changes nothing but the heartbeat.
    if (accuracyM <= session.radiusM) {
      const inside = distance <= session.radiusM;
      if (inside && !session.onSiteSince) {
        next = { ...next, onSiteSince: ctx.timestamp, phase: 'on_site' };
        log(ctx, jobId, 'arrived', `Back on site, ${Math.round(distance)} m from the address`);
      } else if (!inside && session.onSiteSince) {
        next = { ...closeStretch(next, ctx.timestamp), phase: 'away', leftSiteCount: session.leftSiteCount + 1 };
        log(ctx, jobId, 'left', `Left the site, ${Math.round(distance)} m away`);
      } else if (inside && session.phase !== 'on_site') {
        next = { ...next, phase: 'on_site' };
      }
    }
    ctx.db.jobSession.jobId.update(next);
  }
);

// Proof captured in the app: how many checklist items have evidence so far.
export const recordProgress = spacetimedb.reducer({ jobId: t.string(), itemsDone: t.u32() }, (ctx, { jobId, itemsDone }) => {
  requireOwner(ctx);
  const session = ctx.db.jobSession.jobId.find(jobId);
  if (!session || itemsDone === session.itemsDone) return;
  ctx.db.jobSession.jobId.update({ ...session, itemsDone: Math.min(itemsDone, session.itemsTotal), updatedAt: ctx.timestamp });
  log(ctx, jobId, 'progress', `${Math.min(itemsDone, session.itemsTotal)} of ${session.itemsTotal} proof items captured`);
});

// The job moved on in the backend (submitted, verifying, in review, paid, refunded). Submitting ends
// the on-site clock: what's verified is the time spent before the proof went in.
export const setPhase = spacetimedb.reducer({ jobId: t.string(), phase: t.string(), detail: t.string() }, (ctx, { jobId, phase, detail }) => {
  requireOwner(ctx);
  let session = ctx.db.jobSession.jobId.find(jobId);
  if (!session || session.phase === phase) return;
  session = settleStaleness(ctx, session);
  const ending = !ACTIVE.has(phase);
  const next = ending ? closeStretch(session, ctx.timestamp) : session;
  ctx.db.jobSession.jobId.update({ ...next, phase, updatedAt: ctx.timestamp });
  log(ctx, jobId, 'phase', detail);
});

// Every 30 s: sessions whose phone stopped pinging stop accruing on-site time.
export const checkSignals = spacetimedb.reducer({ onSchedule: signalCheck }, { timer: signalCheck.rowType }, (ctx) => {
  for (const session of [...ctx.db.jobSession.iter()]) {
    if (!session.onSiteSince || !ACTIVE.has(session.phase)) continue;
    const settled = settleStaleness(ctx, session);
    if (settled !== session) ctx.db.jobSession.jobId.update({ ...settled, updatedAt: ctx.timestamp });
  }
});
