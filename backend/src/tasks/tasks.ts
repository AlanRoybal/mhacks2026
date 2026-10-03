// Background work started by an API request but not tied to a job (e.g. résumé import).
// Inline mode runs it in-process; deployed, the API invokes the worker Lambda asynchronously.

import { InvokeCommand, LambdaClient } from "@aws-sdk/client-lambda";
import type { ProfileSourceKind } from "../ai/ai.js";
import type { InlineEffectQueue } from "../services/effectQueue.js";

export type Task = { kind: "task"; name: "ingest_profile"; userId: string; blobKey: string; sourceKind: ProfileSourceKind };

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
