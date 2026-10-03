// The services a request or worker needs, built once per process from config.
// Tests build their own with fakes via createDeps(config, overrides).

import { createAi, createEmbedder, type Ai, type Embedder } from "./ai/index.js";
import { loadConfig, type Config } from "./config.js";
import { createLogger, type Logger } from "./lib/log.js";
import { createPushSender, type PushSender } from "./push/index.js";
import { createScheduler, type Scheduler } from "./scheduler/index.js";
import { InlineEffectQueue } from "./services/effectQueue.js";
import { fireTimer } from "./services/timers.js";
import { createStore, type Store } from "./store/index.js";

export interface Deps {
  config: Config;
  store: Store;
  log: Logger;
  now: () => Date;
  push: PushSender;
  scheduler: Scheduler;
  ai: Ai;
  embedder: Embedder;
  // Present when effects run in this process (local dev, tests) instead of from the ledger stream.
  inlineEffects?: InlineEffectQueue;
}

export function createDeps(config: Config = loadConfig(), overrides: Partial<Deps> = {}): Deps {
  const log = overrides.log ?? createLogger();
  const deps: Deps = {
    config,
    store: overrides.store ?? createStore(config),
    log,
    now: () => new Date(),
    push: overrides.push ?? createPushSender(config, log),
    ai: overrides.ai ?? createAi(config, log),
    embedder: overrides.embedder ?? createEmbedder(config),
    // Replaced below; the scheduler's fire callback needs the finished deps object.
    scheduler: overrides.scheduler ?? { schedule: async () => {} },
    inlineEffects: config.EFFECTS_MODE === "inline" ? new InlineEffectQueue(log) : undefined,
    ...overrides,
  };
  if (!overrides.scheduler) deps.scheduler = createScheduler(config, log, (payload) => fireTimer(deps, payload));
  return deps;
}

let shared: Deps | undefined;

// Process-wide deps for Lambda handlers and the local server.
export function getDeps(): Deps {
  shared ??= createDeps();
  return shared;
}
