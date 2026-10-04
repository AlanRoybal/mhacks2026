// Test deps: in-memory store, inline effects, a clock the test controls, no log noise.

import { loadConfig } from "../config.js";
import { createDeps, type Deps } from "../deps.js";
import { silentLogger } from "../lib/log.js";
import { RecordingMessenger } from "../messaging/messenger.js";
import { RecordingPushSender } from "../push/index.js";
import { ManualScheduler } from "../scheduler/localScheduler.js";
import { InlineEffectQueue } from "../services/effectQueue.js";
import { runTask } from "../services/tasks.js";
import { fireTimer } from "../services/timers.js";
import { MemoryStore } from "../store/memoryStore.js";
import { InlineTaskRunner } from "../tasks/tasks.js";

export interface TestDeps extends Deps {
  inlineEffects: InlineEffectQueue;
  clock: { now: Date; advance(seconds: number): void };
  push: RecordingPushSender;
  messenger: RecordingMessenger;
  scheduler: ManualScheduler;
  // Fires due timers and waits for every effect they cause.
  settle(): Promise<void>;
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
  const messenger = new RecordingMessenger();
  const scheduler = new ManualScheduler();
  const deps = createDeps(config, {
    store: new MemoryStore(),
    push,
    messenger,
    scheduler,
    log: silentLogger,
    now: () => clock.now,
    inlineEffects: new InlineEffectQueue(silentLogger),
  });
  const inlineEffects = deps.inlineEffects ?? new InlineEffectQueue(silentLogger);
  const test: TestDeps = {
    ...deps,
    inlineEffects,
    clock,
    push,
    messenger,
    scheduler,
    async settle() {
      await inlineEffects.drain();
      while ((await scheduler.fireDue(clock.now)) > 0) await inlineEffects.drain();
    },
  };
  scheduler.start((payload) => fireTimer(test, payload));
  test.tasks = new InlineTaskRunner(inlineEffects, (task) => runTask(test, task));
  return test;
}
