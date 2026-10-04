import { join } from "node:path";
import type { Config } from "../config.js";
import type { Logger } from "../lib/log.js";
import { EventBridgeScheduler } from "./eventBridgeScheduler.js";
import { LocalScheduler } from "./localScheduler.js";
import type { Scheduler, TimerHandler } from "./scheduler.js";

export function createScheduler(config: Config, log: Logger, fire: TimerHandler): Scheduler {
  if (config.SCHEDULER === "eventbridge") {
    if (!config.SCHEDULER_ROLE_ARN || !config.WORKER_FUNCTION_ARN) {
      throw new Error("SCHEDULER=eventbridge needs SCHEDULER_ROLE_ARN and WORKER_FUNCTION_ARN");
    }
    return new EventBridgeScheduler(
      { region: config.AWS_REGION, groupName: config.SCHEDULER_GROUP, roleArn: config.SCHEDULER_ROLE_ARN, targetArn: config.WORKER_FUNCTION_ARN },
      fire,
      log,
    );
  }
  const local = new LocalScheduler(log, config.DATA_DIR ? join(config.DATA_DIR, "timers.json") : undefined);
  local.start(fire);
  return local;
}

export * from "./scheduler.js";
