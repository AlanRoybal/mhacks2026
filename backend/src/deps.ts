// The services a request or worker needs, built once per process from config.
// Tests build their own with fakes via createDeps(config, overrides).

import { loadConfig, type Config } from "./config.js";
import { createLogger, type Logger } from "./lib/log.js";
import { InlineEffectQueue } from "./services/effectQueue.js";
import { createStore, type Store } from "./store/index.js";

export interface Deps {
  config: Config;
  store: Store;
  log: Logger;
  now: () => Date;
  // Present when effects run in this process (local dev, tests) instead of from the ledger stream.
  inlineEffects?: InlineEffectQueue;
}

export function createDeps(config: Config = loadConfig(), overrides: Partial<Deps> = {}): Deps {
  const log = overrides.log ?? createLogger();
  return {
    config,
    store: createStore(config),
    log,
    now: () => new Date(),
    inlineEffects: config.EFFECTS_MODE === "inline" ? new InlineEffectQueue(log) : undefined,
    ...overrides,
  };
}

let shared: Deps | undefined;

// Process-wide deps for Lambda handlers and the local server.
export function getDeps(): Deps {
  shared ??= createDeps();
  return shared;
}
