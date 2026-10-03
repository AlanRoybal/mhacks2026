import { join } from "node:path";
import type { Config } from "../config.js";
import { DynamoStore } from "./dynamoStore.js";
import { MemoryStore } from "./memoryStore.js";
import type { Store } from "./store.js";

export function createStore(config: Config): Store {
  if (config.STORE === "dynamo") return new DynamoStore(config);
  return new MemoryStore(config.DATA_DIR ? join(config.DATA_DIR, "store.json") : undefined);
}

export * from "./store.js";
