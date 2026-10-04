// SpacetimeDB over its HTTP API: reducers at POST /v1/database/<db>/call/<reducer> (JSON array of args),
// reads at POST /v1/database/<db>/sql. The token is the backend's SpacetimeDB identity, which published
// the database (so it can read its private tables) and claims it on first use (so only it can write).

import type { Logger } from "../lib/log.js";
import type { LiveEvent, LivePhase, LiveSession, LiveSessions, OpenSession } from "./live.js";

interface SqlResult {
  schema: { elements: { name: { some?: string } }[] };
  rows: unknown[][];
}

// SpacetimeDB's JSON: options are [0, value] (some) or [1, []] (none); timestamps are [micros].
const option = <T>(v: unknown): T | undefined => (Array.isArray(v) && v[0] === 0 ? (v[1] as T) : undefined);
const micros = (v: unknown): number => Number(Array.isArray(v) ? v[0] : v);
const iso = (v: unknown): string => new Date(micros(v) / 1000).toISOString();
const isoOption = (v: unknown): string | undefined => {
  const value = option<unknown>(v);
  return value === undefined ? undefined : iso(value);
};
const quote = (s: string) => `'${s.replace(/'/g, "''")}'`;

export class SpacetimeLive implements LiveSessions {
  readonly name = "spacetime";
  private claimed?: Promise<void>;

  constructor(
    private readonly url: string,
    private readonly database: string,
    private readonly token: string,
    private readonly log: Logger,
  ) {}

  private async request(path: string, body: string, contentType: string): Promise<Response> {
    const res = await fetch(`${this.url.replace(/\/$/, "")}/v1/database/${encodeURIComponent(this.database)}/${path}`, {
      method: "POST",
      headers: { authorization: `Bearer ${this.token}`, "content-type": contentType },
      body,
      signal: AbortSignal.timeout(8_000),
    });
    if (!res.ok) throw new Error(`SpacetimeDB ${path} failed: ${res.status} ${await res.text()}`);
    return res;
  }

  private async call(reducer: string, args: unknown[]): Promise<void> {
    this.claimed ??= this.request("call/claim_backend", "[]", "application/json").then(
      () => undefined,
      (error: unknown) => {
        this.claimed = undefined;
        throw error;
      },
    );
    await this.claimed;
    await this.request(`call/${reducer}`, JSON.stringify(args), "application/json");
  }

  private async sql(query: string): Promise<Record<string, unknown>[]> {
    const res = await this.request("sql", query, "text/plain");
    const [result] = (await res.json()) as SqlResult[];
    if (!result) return [];
    const names = result.schema.elements.map((e) => e.name.some ?? "");
    return result.rows.map((row) => Object.fromEntries(names.map((name, i) => [name, row[i]])));
  }

  async open(o: OpenSession): Promise<void> {
    await this.call("open_session", [o.jobId, o.workerId, o.posterId, o.title, o.remote, o.lat, o.lng, o.radiusM, o.itemsTotal, o.startDistanceM, o.startAccuracyM]);
  }

  async ping(jobId: string, lat: number, lng: number, accuracyM: number): Promise<void> {
    await this.call("ping", [jobId, lat, lng, accuracyM]);
  }

  async progress(jobId: string, itemsDone: number): Promise<void> {
    await this.call("record_progress", [jobId, itemsDone]);
  }

  async setPhase(jobId: string, phase: LivePhase, detail: string): Promise<void> {
    await this.call("set_phase", [jobId, phase, detail]);
  }

  async get(jobId: string): Promise<LiveSession | null> {
    const [r] = await this.sql(`SELECT * FROM job_session WHERE job_id = ${quote(jobId)}`);
    if (!r) return null;
    return {
      jobId: String(r.job_id),
      workerId: String(r.worker_id),
      posterId: String(r.poster_id),
      title: String(r.title),
      remote: Boolean(r.remote),
      lat: Number(r.lat),
      lng: Number(r.lng),
      radiusM: Number(r.radius_m),
      phase: String(r.phase) as LivePhase,
      startedAt: iso(r.started_at),
      onSiteSince: isoOption(r.on_site_since),
      onSiteSecondsBanked: Math.floor(Number(r.on_site_micros) / 1_000_000),
      lastPingAt: isoOption(r.last_ping_at),
      lastDistanceM: option<number>(r.last_distance_m),
      lastAccuracyM: option<number>(r.last_accuracy_m),
      pings: Number(r.pings),
      leftSiteCount: Number(r.left_site_count),
      signalLostCount: Number(r.signal_lost_count),
      itemsTotal: Number(r.items_total),
      itemsDone: Number(r.items_done),
      updatedAt: iso(r.updated_at),
    };
  }

  async events(jobId: string): Promise<LiveEvent[]> {
    const rows = await this.sql(`SELECT * FROM session_event WHERE job_id = ${quote(jobId)}`);
    return rows
      .map((r) => ({ at: iso(r.at), kind: String(r.kind) as LiveEvent["kind"], detail: String(r.detail) }))
      .sort((a, b) => a.at.localeCompare(b.at));
  }
}
