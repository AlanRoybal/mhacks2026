import { ConditionalCheckFailedException, TransactionCanceledException, TransactionConflictException } from "@aws-sdk/client-dynamodb";
import assert from "node:assert/strict";
import { test } from "node:test";
import { isWriteConflict } from "./dynamoStore.js";

const meta = { $metadata: {} };

test("version failures and transaction conflicts are both retryable write conflicts", () => {
  assert.equal(isWriteConflict(new ConditionalCheckFailedException({ message: "", ...meta })), true);
  assert.equal(isWriteConflict(new TransactionConflictException({ message: "", ...meta })), true);
  const canceled = (Code: string) => new TransactionCanceledException({ message: "", ...meta, CancellationReasons: [{ Code: "None" }, { Code }] });
  assert.equal(isWriteConflict(canceled("ConditionalCheckFailed")), true);
  assert.equal(isWriteConflict(canceled("TransactionConflict")), true);
  assert.equal(isWriteConflict(canceled("ThrottlingError")), false);
  assert.equal(isWriteConflict(new Error("boom")), false);
});
