// Test deps: in-memory store, inline effects, a clock the test controls, no log noise.

import { loadConfig } from "../config.js";
import { createDeps, type Deps } from "../deps.js";
import { silentLogger } from "../lib/log.js";
import { RecordingPushSender } from "../push/index.js";
import { InlineEffectQueue } from "../services/effectQueue.js";
import { MemoryStore } from "../store/memoryStore.js";

export interface TestDeps extends Deps {
  inlineEffects: InlineEffectQueue;
  clock: { now: Date; advance(seconds: number): void };
  push: RecordingPushSender;
}

export function testDeps(env: Record<string, string> = {}): TestDeps {
  const config = loadConfig({ DATA_DIR: "", ...env });
  const clock = {
    now: new Date("2026-10-04T15:00:00Z"),
    advance(seconds: number) {
      this.now = new Date(this.now.getTime() + seconds * 1000);
    },
  };
  const push = new RecordingPushSender();
  const deps = createDeps(config, {
    store: new MemoryStore(),
    push,
    log: silentLogger,
    now: () => clock.now,
    inlineEffects: new InlineEffectQueue(silentLogger),
  });
  return { ...deps, inlineEffects: deps.inlineEffects ?? new InlineEffectQueue(silentLogger), clock, push };
}
