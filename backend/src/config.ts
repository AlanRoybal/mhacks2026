// Environment configuration. Every setting has a local-dev default, so `npm run dev` works with no .env.

import { z } from "zod";
import { rulesFor, type Rules } from "./domain/rules.js";

const bool = z
  .enum(["true", "false", "1", "0", ""])
  .default("false")
  .transform((v) => v === "true" || v === "1");

const schema = z.object({
  STAGE: z.string().default("local"),
  DEMO_MODE: bool,
  STORE: z.enum(["memory", "dynamo"]).default("memory"),
  // inline: effects run in this process after each commit (local dev).
  // stream: the worker Lambda runs them from the ledger table's DynamoDB Stream (deployed).
  EFFECTS_MODE: z.enum(["inline", "stream"]).default("inline"),
  // Memory store snapshot directory. Empty string keeps everything in memory only.
  DATA_DIR: z.string().default(".data"),
  JOBS_TABLE: z.string().optional(),
  USERS_TABLE: z.string().optional(),
  OFFERS_TABLE: z.string().optional(),
  PROOFS_TABLE: z.string().optional(),
  LEDGER_TABLE: z.string().optional(),
  KV_TABLE: z.string().optional(),
  AWS_REGION: z.string().default("us-east-1"),
});

export type Env = z.infer<typeof schema>;

export interface Config extends Env {
  rules: Rules;
  tables: { jobs: string; users: string; offers: string; proofs: string; ledger: string; kv: string };
}

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const problems = parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ");
    throw new Error(`Invalid configuration: ${problems}`);
  }
  const e = parsed.data;
  const table = (name: string, override?: string) => override ?? `bounty-${e.STAGE}-${name}`;
  return {
    ...e,
    rules: rulesFor(e.DEMO_MODE),
    tables: {
      jobs: table("jobs", e.JOBS_TABLE),
      users: table("users", e.USERS_TABLE),
      offers: table("offers", e.OFFERS_TABLE),
      proofs: table("proofs", e.PROOFS_TABLE),
      ledger: table("ledger", e.LEDGER_TABLE),
      kv: table("kv", e.KV_TABLE),
    },
  };
}
