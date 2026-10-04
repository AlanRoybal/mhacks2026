// The services a request or worker needs, built once per process from config.
// Tests build their own with fakes via createDeps(config, overrides).

import { createAi, createEmbedder, type Ai, type Embedder } from "./ai/index.js";
import { createBlobs, type Blobs } from "./blobs/index.js";
import { loadConfig, type Config } from "./config.js";
import { createLogger, type Logger } from "./lib/log.js";
import { createLive, type LiveSessions } from "./live/index.js";
import { createMessenger, type Messenger } from "./messaging/messenger.js";
import { createPayments, type Payments } from "./payments/index.js";
import { createPushSender, type PushSender } from "./push/index.js";
import { createScheduler, type Scheduler } from "./scheduler/index.js";
import { InlineEffectQueue } from "./services/effectQueue.js";
import { runTask } from "./services/tasks.js";
import { fireTimer } from "./services/timers.js";
import { createStore, type Store } from "./store/index.js";
import { InlineTaskRunner, LambdaTaskRunner, type TaskRunner } from "./tasks/tasks.js";

export interface Deps {
  config: Config;
  store: Store;
  log: Logger;
  now: () => Date;
  push: PushSender;
  messenger: Messenger;
  // Live job sessions in SpacetimeDB (or the in-memory twin).
  live: LiveSessions;
  scheduler: Scheduler;
  ai: Ai;
  embedder: Embedder;
  blobs: Blobs;
  payments: Payments;
  tasks: TaskRunner;
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
    messenger: overrides.messenger ?? createMessenger(config, log),
    // Reads deps.now lazily, so tests that move the clock move the in-memory twin too.
    live: overrides.live ?? createLive(config, log, () => deps.now()),
    ai: overrides.ai ?? createAi(config, log),
    embedder: overrides.embedder ?? createEmbedder(config),
    blobs: overrides.blobs ?? createBlobs(config),
    payments: overrides.payments ?? createPayments(config),
    // Replaced below; the scheduler and task runner call back into the finished deps object.
    scheduler: overrides.scheduler ?? { schedule: async () => {} },
    tasks: overrides.tasks ?? { run: async () => {} },
    inlineEffects: config.EFFECTS_MODE === "inline" ? new InlineEffectQueue(log) : undefined,
    ...overrides,
  };
  if (!overrides.scheduler) deps.scheduler = createScheduler(config, log, (payload) => fireTimer(deps, payload));
  if (!overrides.tasks) deps.tasks = createTaskRunner(deps);
  return deps;
}

function createTaskRunner(deps: Deps): TaskRunner {
  if (deps.inlineEffects) return new InlineTaskRunner(deps.inlineEffects, (task) => runTask(deps, task));
  if (!deps.config.WORKER_FUNCTION_ARN) throw new Error("EFFECTS_MODE=stream needs WORKER_FUNCTION_ARN for background tasks");
  return new LambdaTaskRunner(deps.config.AWS_REGION, deps.config.WORKER_FUNCTION_ARN);
}

let shared: Deps | undefined;

// Process-wide deps for Lambda handlers and the local server.
export function getDeps(): Deps {
  shared ??= createDeps();
  return shared;
}
