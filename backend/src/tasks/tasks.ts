// Background work that should not run inside a request or the ordered ledger stream: résumé import,
// AI grading and matching. Inline mode runs it in-process; deployed, it is an asynchronous invocation
// of the worker Lambda (which retries twice on failure).

import { InvokeCommand, LambdaClient } from "@aws-sdk/client-lambda";
import type { ProfileSourceKind } from "../ai/ai.js";
import type { InlineEffectQueue } from "../services/effectQueue.js";

export type Task =
  | { kind: "task"; name: "ingest_profile"; userId: string; blobKey: string; sourceKind: ProfileSourceKind }
  // Sent-mail text read during POST /twin/gmail (capped at 50k chars). The Google token is already revoked.
  | { kind: "task"; name: "ingest_gmail"; userId: string; text: string }
  // Slow, AI-bound effects run as their own invocations so they never hold up the ordered ledger stream.
  | { kind: "task"; name: "grade_proof"; jobId: string; proofId: string }
  | { kind: "task"; name: "match_job"; jobId: string };

export interface TaskRunner {
  run(task: Task): Promise<void>;
}

export class InlineTaskRunner implements TaskRunner {
  constructor(
    private readonly queue: InlineEffectQueue,
    private readonly handler: (task: Task) => Promise<void>,
  ) {}

  async run(task: Task): Promise<void> {
    this.queue.enqueue(`task:${task.name}`, () => this.handler(task));
  }
}

export class LambdaTaskRunner implements TaskRunner {
  private readonly client: LambdaClient;

  constructor(
    region: string,
    private readonly functionArn: string,
  ) {
    this.client = new LambdaClient({ region });
  }

  async run(task: Task): Promise<void> {
    await this.client.send(new InvokeCommand({ FunctionName: this.functionArn, InvocationType: "Event", Payload: Buffer.from(JSON.stringify(task)) }));
  }
}
