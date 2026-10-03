import type { Logger } from "../lib/log.js";

// Runs effect batches one after another in this process, in commit order.
// Used in local dev and tests instead of the DynamoDB Stream → worker Lambda path.
export class InlineEffectQueue {
  private tail: Promise<void> = Promise.resolve();
  private pending = 0;

  constructor(private readonly log: Logger) {}

  enqueue(label: string, task: () => Promise<void>): void {
    this.pending++;
    this.tail = this.tail
      .then(task)
      .catch((error: unknown) => this.log.error("Inline effects failed", { label, error }))
      .finally(() => {
        this.pending--;
      });
  }

  // Resolves once every queued batch, including batches queued by those batches, has run.
  async drain(): Promise<void> {
    while (this.pending > 0) await this.tail;
  }
}
