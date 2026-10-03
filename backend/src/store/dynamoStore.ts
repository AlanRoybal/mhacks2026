// DynamoDB implementation. Table and index names match infra/stack.ts.
//
// Keys:
//   jobs    PK jobId              GSIs byPoster(posterId, createdAt), byWorker(workerId, updatedAt)
//   users   PK userId
//   offers  PK offerId            GSIs byJob(jobId, createdAt), byWorker(workerId, createdAt)
//   proofs  PK jobId, SK proofId
//   ledger  PK jobId, SK seq      (stream enabled: drives the outbox worker)
//   kv      PK key                (TTL attribute expiresAt)

import { ConditionalCheckFailedException, DynamoDBClient, TransactionCanceledException } from "@aws-sdk/client-dynamodb";
import {
  DeleteCommand,
  DynamoDBDocumentClient,
  GetCommand,
  PutCommand,
  QueryCommand,
  ScanCommand,
  TransactWriteCommand,
  UpdateCommand,
  type QueryCommandInput,
} from "@aws-sdk/lib-dynamodb";
import type { Config } from "../config.js";
import type { LedgerEvent } from "../domain/events.js";
import type { Job, Offer, Proof, User } from "../domain/types.js";
import { AlreadyExistsError, needsAttention, VersionConflictError, type Store } from "./store.js";

const isConditionFailure = (e: unknown) =>
  e instanceof ConditionalCheckFailedException ||
  (e instanceof TransactionCanceledException && (e.CancellationReasons ?? []).some((r) => r.Code === "ConditionalCheckFailed"));

export class DynamoStore implements Store {
  private readonly db: DynamoDBDocumentClient;
  private readonly t: Config["tables"];

  constructor(config: Config) {
    this.db = DynamoDBDocumentClient.from(new DynamoDBClient({ region: config.AWS_REGION }), {
      marshallOptions: { removeUndefinedValues: true },
    });
    this.t = config.tables;
  }

  private async queryAll<T>(input: QueryCommandInput): Promise<T[]> {
    const items: T[] = [];
    let ExclusiveStartKey: Record<string, unknown> | undefined;
    do {
      const page = await this.db.send(new QueryCommand({ ...input, ExclusiveStartKey }));
      items.push(...((page.Items ?? []) as T[]));
      ExclusiveStartKey = page.LastEvaluatedKey;
    } while (ExclusiveStartKey);
    return items;
  }

  private async scanAll<T>(TableName: string): Promise<T[]> {
    const items: T[] = [];
    let ExclusiveStartKey: Record<string, unknown> | undefined;
    do {
      const page = await this.db.send(new ScanCommand({ TableName, ExclusiveStartKey }));
      items.push(...((page.Items ?? []) as T[]));
      ExclusiveStartKey = page.LastEvaluatedKey;
    } while (ExclusiveStartKey);
    return items;
  }

  // Put that only succeeds if the stored item still has version prevVersion.
  private versionedPut(TableName: string, Item: object, prevVersion: number) {
    return {
      TableName,
      Item,
      ConditionExpression: "#v = :v",
      ExpressionAttributeNames: { "#v": "version" },
      ExpressionAttributeValues: { ":v": prevVersion },
    };
  }

  async getJob(jobId: string) {
    const r = await this.db.send(new GetCommand({ TableName: this.t.jobs, Key: { jobId }, ConsistentRead: true }));
    return (r.Item as Job | undefined) ?? null;
  }

  async createJob(job: Job, created: LedgerEvent) {
    try {
      await this.db.send(
        new TransactWriteCommand({
          TransactItems: [
            { Put: { TableName: this.t.jobs, Item: job, ConditionExpression: "attribute_not_exists(jobId)" } },
            { Put: { TableName: this.t.ledger, Item: created, ConditionExpression: "attribute_not_exists(seq)" } },
          ],
        }),
      );
    } catch (e) {
      if (isConditionFailure(e)) throw new AlreadyExistsError(`Job ${job.jobId}`);
      throw e;
    }
  }

  async commitTransition(prevVersion: number, next: Job, event: LedgerEvent) {
    try {
      await this.db.send(
        new TransactWriteCommand({
          TransactItems: [
            { Put: this.versionedPut(this.t.jobs, next, prevVersion) },
            { Put: { TableName: this.t.ledger, Item: event, ConditionExpression: "attribute_not_exists(seq)" } },
          ],
        }),
      );
    } catch (e) {
      if (isConditionFailure(e)) throw new VersionConflictError(`Job ${next.jobId}`);
      throw e;
    }
  }

  async saveJob(prevVersion: number, next: Job) {
    try {
      await this.db.send(new PutCommand(this.versionedPut(this.t.jobs, next, prevVersion)));
    } catch (e) {
      if (isConditionFailure(e)) throw new VersionConflictError(`Job ${next.jobId}`);
      throw e;
    }
  }

  async deleteJob(jobId: string, prevVersion: number) {
    try {
      await this.db.send(
        new DeleteCommand({
          TableName: this.t.jobs,
          Key: { jobId },
          ConditionExpression: "#v = :v",
          ExpressionAttributeNames: { "#v": "version" },
          ExpressionAttributeValues: { ":v": prevVersion },
        }),
      );
    } catch (e) {
      if (isConditionFailure(e)) throw new VersionConflictError(`Job ${jobId}`);
      throw e;
    }
  }

  listJobsByPoster(userId: string) {
    return this.queryAll<Job>({
      TableName: this.t.jobs,
      IndexName: "byPoster",
      KeyConditionExpression: "posterId = :u",
      ExpressionAttributeValues: { ":u": userId },
      ScanIndexForward: false,
    });
  }

  listJobsByWorker(userId: string) {
    return this.queryAll<Job>({
      TableName: this.t.jobs,
      IndexName: "byWorker",
      KeyConditionExpression: "workerId = :u",
      ExpressionAttributeValues: { ":u": userId },
      ScanIndexForward: false,
    });
  }

  async listJobsNeedingAttention() {
    const items: Job[] = [];
    let ExclusiveStartKey: Record<string, unknown> | undefined;
    do {
      const page = await this.db.send(
        new ScanCommand({
          TableName: this.t.jobs,
          ExclusiveStartKey,
          FilterExpression:
            "#s <> :draft AND ((NOT #s IN (:released, :refunded)) OR (#s = :released AND attribute_not_exists(#p.#tr)) OR (#s = :refunded AND attribute_not_exists(#p.#rf)))",
          ExpressionAttributeNames: { "#s": "state", "#p": "payment", "#tr": "transferId", "#rf": "refundId" },
          ExpressionAttributeValues: { ":draft": "DRAFT", ":released": "RELEASED", ":refunded": "REFUNDED" },
        }),
      );
      items.push(...((page.Items ?? []) as Job[]));
      ExclusiveStartKey = page.LastEvaluatedKey;
    } while (ExclusiveStartKey);
    // The filter above is an optimization; the shared predicate is the source of truth.
    return items.filter(needsAttention);
  }

  listLedger(jobId: string) {
    return this.queryAll<LedgerEvent>({
      TableName: this.t.ledger,
      KeyConditionExpression: "jobId = :j",
      ExpressionAttributeValues: { ":j": jobId },
      ConsistentRead: true,
    });
  }

  async getUser(userId: string) {
    const r = await this.db.send(new GetCommand({ TableName: this.t.users, Key: { userId }, ConsistentRead: true }));
    return (r.Item as User | undefined) ?? null;
  }

  async createUser(user: User) {
    try {
      await this.db.send(new PutCommand({ TableName: this.t.users, Item: user, ConditionExpression: "attribute_not_exists(userId)" }));
    } catch (e) {
      if (isConditionFailure(e)) throw new AlreadyExistsError(`User ${user.userId}`);
      throw e;
    }
  }

  async saveUser(prevVersion: number, next: User) {
    try {
      await this.db.send(new PutCommand(this.versionedPut(this.t.users, next, prevVersion)));
    } catch (e) {
      if (isConditionFailure(e)) throw new VersionConflictError(`User ${next.userId}`);
      throw e;
    }
  }

  listUsers() {
    return this.scanAll<User>(this.t.users);
  }

  async createOffers(offers: Offer[]) {
    for (const offer of offers) {
      try {
        await this.db.send(new PutCommand({ TableName: this.t.offers, Item: offer, ConditionExpression: "attribute_not_exists(offerId)" }));
      } catch (e) {
        if (!isConditionFailure(e)) throw e;
      }
    }
  }

  async getOffer(offerId: string) {
    const r = await this.db.send(new GetCommand({ TableName: this.t.offers, Key: { offerId }, ConsistentRead: true }));
    return (r.Item as Offer | undefined) ?? null;
  }

  async updateOffer(offerId: string, patch: Partial<Offer>) {
    const entries = Object.entries(patch).filter(([k, v]) => k !== "offerId" && v !== undefined);
    if (entries.length === 0) return;
    try {
      await this.db.send(
        new UpdateCommand({
          TableName: this.t.offers,
          Key: { offerId },
          ConditionExpression: "attribute_exists(offerId)",
          UpdateExpression: `SET ${entries.map((_, i) => `#k${i} = :v${i}`).join(", ")}`,
          ExpressionAttributeNames: Object.fromEntries(entries.map(([k], i) => [`#k${i}`, k])),
          ExpressionAttributeValues: Object.fromEntries(entries.map(([, v], i) => [`:v${i}`, v])),
        }),
      );
    } catch (e) {
      if (!isConditionFailure(e)) throw e;
    }
  }

  async listOffersForJob(jobId: string) {
    const offers = await this.queryAll<Offer>({
      TableName: this.t.offers,
      IndexName: "byJob",
      KeyConditionExpression: "jobId = :j",
      ExpressionAttributeValues: { ":j": jobId },
    });
    return offers.sort((a, b) => a.round - b.round || a.rank - b.rank);
  }

  listOffersForWorker(workerId: string) {
    return this.queryAll<Offer>({
      TableName: this.t.offers,
      IndexName: "byWorker",
      KeyConditionExpression: "workerId = :w",
      ExpressionAttributeValues: { ":w": workerId },
      ScanIndexForward: false,
    });
  }

  async putProof(proof: Proof) {
    await this.db.send(new PutCommand({ TableName: this.t.proofs, Item: proof }));
  }

  async getProof(jobId: string, proofId: string) {
    const r = await this.db.send(new GetCommand({ TableName: this.t.proofs, Key: { jobId, proofId }, ConsistentRead: true }));
    return (r.Item as Proof | undefined) ?? null;
  }

  async listProofs(jobId: string) {
    const proofs = await this.queryAll<Proof>({
      TableName: this.t.proofs,
      KeyConditionExpression: "jobId = :j",
      ExpressionAttributeValues: { ":j": jobId },
      ConsistentRead: true,
    });
    return proofs.sort((a, b) => b.createdAt.localeCompare(a.createdAt));
  }

  async kvGet<T>(key: string) {
    const r = await this.db.send(new GetCommand({ TableName: this.t.kv, Key: { key }, ConsistentRead: true }));
    const item = r.Item as { value: T; expiresAt?: number } | undefined;
    // DynamoDB deletes expired items lazily, so check the TTL ourselves.
    if (!item || (item.expiresAt !== undefined && item.expiresAt <= Date.now() / 1000)) return null;
    return item.value;
  }

  async kvPut(key: string, value: unknown, opts: { ifAbsent?: boolean; ttlSeconds?: number } = {}) {
    const now = Math.floor(Date.now() / 1000);
    const expiresAt = opts.ttlSeconds ? now + opts.ttlSeconds : undefined;
    try {
      await this.db.send(
        new PutCommand({
          TableName: this.t.kv,
          Item: { key, value, expiresAt },
          ...(opts.ifAbsent
            ? {
                ConditionExpression: "attribute_not_exists(#k) OR #e <= :now",
                ExpressionAttributeNames: { "#k": "key", "#e": "expiresAt" },
                ExpressionAttributeValues: { ":now": now },
              }
            : {}),
        }),
      );
      return true;
    } catch (e) {
      if (opts.ifAbsent && isConditionFailure(e)) return false;
      throw e;
    }
  }
}
