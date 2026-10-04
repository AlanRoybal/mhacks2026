// Small HTTP helpers for API tests: call routes the way the iOS app does.

import { createApp } from "../api/app.js";
import type { TestDeps } from "./harness.js";

export type Json = Record<string, any>;

export function apiClient(deps: TestDeps) {
  const app = createApp(deps);
  const base = deps.config.PUBLIC_BASE_URL;

  async function call(method: string, path: string, token?: string, body?: unknown) {
    const res = await app.request(path.replace(base, ""), {
      method,
      headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    return { status: res.status, body: (text ? JSON.parse(text) : {}) as Json };
  }

  async function login(handle: string): Promise<{ token: string; userId: string }> {
    const { body } = await call("POST", "/auth/demo", undefined, { handle });
    return { token: body.token, userId: body.userId };
  }

  // A worker who is ready to match: one skill, a push token, and a base location.
  async function readyWorker(handle: string, opts: { skill: string; lat: number; lng: number; prefs?: Json }) {
    const w = await login(handle);
    await call("POST", "/twin/skills", w.token, { name: opts.skill, level: 4 });
    await call("POST", "/me/devices", w.token, { token: handle.padEnd(64, "0").replace(/[^0-9a-f]/g, "a").slice(0, 64), env: "sandbox" });
    await call("PUT", "/twin/prefs", w.token, { base: { latitude: opts.lat, longitude: opts.lng }, ...opts.prefs });
    return w;
  }

  return { app, call, login, readyWorker };
}

export const isoIn = (deps: TestDeps, hours: number) => new Date(deps.now().getTime() + hours * 3600_000).toISOString().replace(/\.\d{3}Z$/, "Z");
