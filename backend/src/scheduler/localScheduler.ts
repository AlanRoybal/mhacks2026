// In-process timers for local dev. Pending timers are saved to a JSON file and re-armed on restart,
// so `tsx watch` reloads don't lose offer expiries or review windows.

import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import type { Logger } from "../lib/log.js";
import type { Scheduler, TimerHandler, TimerPayload } from "./scheduler.js";

const MAX_TIMEOUT_MS = 2 ** 31 - 1;

export class LocalScheduler implements Scheduler {
  private readonly pending = new Map<string, TimerPayload>();
  private handler?: TimerHandler;

  constructor(
    private readonly log: Logger,
    private readonly file?: string,
  ) {
    if (file && existsSync(file)) {
      for (const [name, payload] of Object.entries(JSON.parse(readFileSync(file, "utf8")) as Record<string, TimerPayload>)) {
        this.pending.set(name, payload);
      }
    }
  }

  // Called once deps exist. Arms everything restored from disk.
  start(handler: TimerHandler): void {
    this.handler = handler;
    for (const [name, payload] of this.pending) this.arm(name, payload);
  }

  async schedule(name: string, payload: TimerPayload): Promise<void> {
    if (this.pending.has(name)) return;
    this.pending.set(name, payload);
    this.save();
    this.arm(name, payload);
  }

  private arm(name: string, payload: TimerPayload): void {
    if (!this.handler) return;
    const delay = Math.max(0, Date.parse(payload.at) - Date.now());
    const timeout = setTimeout(() => {
      if (Date.parse(payload.at) > Date.now()) return this.arm(name, payload);
      this.pending.delete(name);
      this.save();
      this.handler?.(payload).catch((error: unknown) => this.log.error("Timer failed", { name, error }));
    }, Math.min(delay, MAX_TIMEOUT_MS));
    timeout.unref();
  }

  private save(): void {
    if (!this.file) return;
    mkdirSync(dirname(this.file), { recursive: true });
    writeFileSync(this.file, JSON.stringify(Object.fromEntries(this.pending)));
  }
}

// Tests: nothing fires until the test calls fireDue().
export class ManualScheduler implements Scheduler {
  readonly pending = new Map<string, TimerPayload>();
  private handler?: TimerHandler;

  start(handler: TimerHandler): void {
    this.handler = handler;
  }

  async schedule(name: string, payload: TimerPayload): Promise<void> {
    if (!this.pending.has(name)) this.pending.set(name, payload);
  }

  // Fires every timer due at `now`, oldest first. Returns how many fired.
  async fireDue(now: Date): Promise<number> {
    const due = [...this.pending.entries()]
      .filter(([, p]) => Date.parse(p.at) <= now.getTime())
      .sort(([, a], [, b]) => Date.parse(a.at) - Date.parse(b.at));
    for (const [name, payload] of due) {
      this.pending.delete(name);
      await this.handler?.(payload);
    }
    return due.length;
  }
}
