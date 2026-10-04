// One-shot EventBridge Scheduler schedules that invoke the worker Lambda. They delete themselves after
// firing. Nothing ever cancels a schedule: the state machine rejects timers that no longer apply.

import { ConflictException, CreateScheduleCommand, SchedulerClient } from "@aws-sdk/client-scheduler";
import type { Logger } from "../lib/log.js";
import type { Scheduler, TimerHandler, TimerPayload } from "./scheduler.js";

// Schedules this close to now are fired directly; EventBridge rejects times in the past.
const DIRECT_FIRE_MS = 5_000;

export class EventBridgeScheduler implements Scheduler {
  private readonly client: SchedulerClient;

  constructor(
    private readonly cfg: { region: string; groupName: string; roleArn: string; targetArn: string },
    private readonly fireNow: TimerHandler,
    private readonly log: Logger,
  ) {
    this.client = new SchedulerClient({ region: cfg.region });
  }

  async schedule(name: string, payload: TimerPayload): Promise<void> {
    const at = Date.parse(payload.at);
    if (at - Date.now() < DIRECT_FIRE_MS) {
      // Wait out the last few seconds so the event isn't rejected as early.
      const wait = at - Date.now();
      if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait + 50));
      await this.fireNow(payload);
      return;
    }
    // at() takes yyyy-mm-ddThh:mm:ss with no zone suffix; the zone is given separately.
    const expression = `at(${new Date(Math.ceil(at / 1000) * 1000).toISOString().slice(0, 19)})`;
    try {
      await this.client.send(
        new CreateScheduleCommand({
          Name: name,
          GroupName: this.cfg.groupName,
          ScheduleExpression: expression,
          ScheduleExpressionTimezone: "UTC",
          FlexibleTimeWindow: { Mode: "OFF" },
          ActionAfterCompletion: "DELETE",
          Target: {
            Arn: this.cfg.targetArn,
            RoleArn: this.cfg.roleArn,
            Input: JSON.stringify(payload),
            RetryPolicy: { MaximumRetryAttempts: 5, MaximumEventAgeInSeconds: 3600 },
          },
        }),
      );
      this.log.info("Timer scheduled", { name, at: payload.at });
    } catch (e) {
      if (e instanceof ConflictException) return;
      throw e;
    }
  }
}
