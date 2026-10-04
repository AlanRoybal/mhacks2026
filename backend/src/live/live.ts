// Live job sessions: the port to SpacetimeDB (spacetime/src/index.ts), where on-site time, the geofence,
// "left the site", proof progress and the job's live phase are decided. Two implementations:
//   SpacetimeLive  the real one: calls the module's reducers and reads its tables over HTTP
//   MemoryLive     tests and offline local dev: the same rules, in process
// Keep MemoryLive's rules identical to the module's.

export type LivePhase = "started" | "on_site" | "away" | "signal_lost" | "submitted" | "verifying" | "in_review" | "paid" | "refunded" | "closed";

export interface LiveSession {
  jobId: string;
  workerId: string;
  posterId: string;
  title: string;
  remote: boolean;
  lat: number;
  lng: number;
  radiusM: number;
  phase: LivePhase;
  startedAt: string;
  // The current on-site stretch, if on site now.
  onSiteSince?: string;
  // Finished stretches, in seconds.
  onSiteSecondsBanked: number;
  lastPingAt?: string;
  lastDistanceM?: number;
  lastAccuracyM?: number;
  pings: number;
  leftSiteCount: number;
  signalLostCount: number;
  itemsTotal: number;
  itemsDone: number;
  updatedAt: string;
}

export interface LiveEvent {
  at: string;
  kind: "arrived" | "left" | "signal_lost" | "progress" | "phase";
  detail: string;
}

export interface OpenSession {
  jobId: string;
  workerId: string;
  posterId: string;
  title: string;
  remote: boolean;
  lat: number;
  lng: number;
  radiusM: number;
  itemsTotal: number;
  startDistanceM: number;
  startAccuracyM: number;
}

export interface LiveSessions {
  readonly name: string;
  open(session: OpenSession): Promise<void>;
  ping(jobId: string, lat: number, lng: number, accuracyM: number): Promise<void>;
  progress(jobId: string, itemsDone: number): Promise<void>;
  setPhase(jobId: string, phase: LivePhase, detail: string): Promise<void>;
  get(jobId: string): Promise<LiveSession | null>;
  events(jobId: string): Promise<LiveEvent[]>;
}

export const ACTIVE_PHASES: ReadonlySet<LivePhase> = new Set(["started", "on_site", "away", "signal_lost"]);
// Same as the module: a ping older than this means the phone stopped reporting.
export const STALE_MS = 90_000;

// Total on-site time as of `now`, counting the current stretch only up to the last ping if the phone
// went quiet (the scheduled reducer in SpacetimeDB settles that within 30 s anyway).
export function onSiteSeconds(session: LiveSession, now: Date): number {
  if (!session.onSiteSince) return session.onSiteSecondsBanked;
  const since = Date.parse(session.onSiteSince);
  const lastPing = session.lastPingAt ? Date.parse(session.lastPingAt) : now.getTime();
  const end = now.getTime() - lastPing > STALE_MS ? lastPing : now.getTime();
  return session.onSiteSecondsBanked + Math.max(0, Math.floor((end - since) / 1000));
}

function haversineM(lat1: number, lng1: number, lat2: number, lng2: number): number {
  const rad = (d: number) => (d * Math.PI) / 180;
  const a = Math.sin(rad(lat2 - lat1) / 2) ** 2 + Math.cos(rad(lat1)) * Math.cos(rad(lat2)) * Math.sin(rad(lng2 - lng1) / 2) ** 2;
  return 2 * 6_371_000 * Math.asin(Math.min(1, Math.sqrt(a)));
}

// In-process stand-in with the module's rules, for tests and local dev without SpacetimeDB.
export class MemoryLive implements LiveSessions {
  readonly name = "memory";
  private readonly sessions = new Map<string, LiveSession>();
  private readonly log = new Map<string, LiveEvent[]>();

  constructor(private readonly now: () => Date) {}

  private event(jobId: string, kind: LiveEvent["kind"], detail: string): void {
    const list = this.log.get(jobId) ?? [];
    list.push({ at: this.now().toISOString(), kind, detail });
    this.log.set(jobId, list);
  }

  private closeStretch(s: LiveSession, at: string): void {
    if (!s.onSiteSince) return;
    s.onSiteSecondsBanked += Math.max(0, Math.floor((Date.parse(at) - Date.parse(s.onSiteSince)) / 1000));
    s.onSiteSince = undefined;
  }

  private settleStaleness(s: LiveSession): void {
    if (!s.onSiteSince || !s.lastPingAt) return;
    if (this.now().getTime() - Date.parse(s.lastPingAt) <= STALE_MS) return;
    this.event(s.jobId, "signal_lost", "Location stopped updating; on-site time paused at the last check");
    this.closeStretch(s, s.lastPingAt);
    s.phase = "signal_lost";
    s.signalLostCount++;
  }

  async open(o: OpenSession): Promise<void> {
    const now = this.now().toISOString();
    this.log.delete(o.jobId);
    this.sessions.set(o.jobId, {
      ...o,
      phase: o.remote ? "started" : "on_site",
      startedAt: now,
      onSiteSince: o.remote ? undefined : now,
      onSiteSecondsBanked: 0,
      lastPingAt: o.remote ? undefined : now,
      lastDistanceM: o.remote ? undefined : o.startDistanceM,
      lastAccuracyM: o.remote ? undefined : o.startAccuracyM,
      pings: o.remote ? 0 : 1,
      leftSiteCount: 0,
      signalLostCount: 0,
      itemsDone: 0,
      updatedAt: now,
    });
    this.event(o.jobId, o.remote ? "phase" : "arrived", o.remote ? "Started" : `Started on site, ${Math.round(o.startDistanceM)} m from the address`);
  }

  async ping(jobId: string, lat: number, lng: number, accuracyM: number): Promise<void> {
    const s = this.sessions.get(jobId);
    if (!s || s.remote || !ACTIVE_PHASES.has(s.phase)) return;
    this.settleStaleness(s);
    const now = this.now().toISOString();
    const distance = haversineM(lat, lng, s.lat, s.lng);
    s.lastPingAt = now;
    s.lastDistanceM = distance;
    s.lastAccuracyM = accuracyM;
    s.pings++;
    s.updatedAt = now;
    if (accuracyM > s.radiusM) return;
    const inside = distance <= s.radiusM;
    if (inside && !s.onSiteSince) {
      s.onSiteSince = now;
      s.phase = "on_site";
      this.event(jobId, "arrived", `Back on site, ${Math.round(distance)} m from the address`);
    } else if (!inside && s.onSiteSince) {
      this.closeStretch(s, now);
      s.phase = "away";
      s.leftSiteCount++;
      this.event(jobId, "left", `Left the site, ${Math.round(distance)} m away`);
    } else if (inside && s.phase !== "on_site") {
      s.phase = "on_site";
    }
  }

  async progress(jobId: string, itemsDone: number): Promise<void> {
    const s = this.sessions.get(jobId);
    if (!s || itemsDone === s.itemsDone) return;
    s.itemsDone = Math.min(itemsDone, s.itemsTotal);
    s.updatedAt = this.now().toISOString();
    this.event(jobId, "progress", `${s.itemsDone} of ${s.itemsTotal} proof items captured`);
  }

  async setPhase(jobId: string, phase: LivePhase, detail: string): Promise<void> {
    const s = this.sessions.get(jobId);
    if (!s || s.phase === phase) return;
    this.settleStaleness(s);
    if (!ACTIVE_PHASES.has(phase)) this.closeStretch(s, this.now().toISOString());
    s.phase = phase;
    s.updatedAt = this.now().toISOString();
    this.event(jobId, "phase", detail);
  }

  async get(jobId: string): Promise<LiveSession | null> {
    const s = this.sessions.get(jobId);
    return s ? structuredClone(s) : null;
  }

  async events(jobId: string): Promise<LiveEvent[]> {
    return [...(this.log.get(jobId) ?? [])];
  }
}
