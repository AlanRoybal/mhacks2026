// Worker Lambda. Three kinds of input:
//   1. DynamoDB Stream batches from the ledger table: run each new row's effects (the outbox).
//   2. Timer payloads from EventBridge Scheduler.
//   3. Background tasks invoked asynchronously by the API (see services/tasks.ts).

import type { AttributeValue } from "@aws-sdk/client-dynamodb";
import { unmarshall } from "@aws-sdk/util-dynamodb";
import type { DynamoDBBatchResponse, DynamoDBStreamEvent } from "aws-lambda";
import { getDeps } from "../deps.js";
import type { LedgerEvent } from "../domain/events.js";
import type { TimerPayload } from "../scheduler/index.js";
import { runEffects } from "../services/effects.js";
import { fireTimer } from "../services/timers.js";

type WorkerEvent = DynamoDBStreamEvent | TimerPayload | { kind: string };

const isStream = (e: WorkerEvent): e is DynamoDBStreamEvent => "Records" in e;

export async function handler(event: WorkerEvent): Promise<DynamoDBBatchResponse | void> {
  const deps = getDeps();

  if (isStream(event)) {
    // Records are processed in order. On the first failure we stop and report it; Lambda retries from
    // that record, so later records for the same job never run ahead of an earlier one.
    for (const record of event.Records) {
      const image = record.dynamodb?.NewImage;
      if (record.eventName !== "INSERT" || !image) continue;
      const ledger = unmarshall(image as Record<string, AttributeValue>) as LedgerEvent;
      if (ledger.inline || ledger.effects.length === 0) continue;
      try {
        await runEffects(deps, ledger);
      } catch (error) {
        deps.log.error("Ledger record failed; will retry", { jobId: ledger.jobId, seq: ledger.seq, error });
        return { batchItemFailures: [{ itemIdentifier: record.dynamodb?.SequenceNumber ?? "" }] };
      }
    }
    return { batchItemFailures: [] };
  }

  if (event.kind === "timer") {
    await fireTimer(deps, event as TimerPayload);
    return;
  }

  deps.log.warn("Unknown worker event", { kind: event.kind });
}
