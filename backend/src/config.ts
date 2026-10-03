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

  PORT: z.coerce.number().int().default(8787),
  // Public URL of this API. Used for OAuth redirects and presigned local uploads.
  PUBLIC_BASE_URL: z.string().url().default("http://localhost:8787"),
  // Signs session tokens. Must be set outside local dev.
  JWT_SECRET: z.string().min(32).optional(),
  // Custom URL scheme the iOS app registers; sign-in redirects back to <scheme>://auth?token=...
  APP_URL_SCHEME: z.string().default("bountytwin"),
  APPLE_BUNDLE_ID: z.string().default("com.alanroybal.BountyTwin"),
  LINKEDIN_CLIENT_ID: z.string().optional(),
  LINKEDIN_CLIENT_SECRET: z.string().optional(),
  // Comma-separated user IDs allowed to resolve disputes.
  ADMIN_USER_IDS: z.string().default(""),

  // console: log pushes (local dev). apns: send through Apple with the .p8 key below.
  PUSH_PROVIDER: z.enum(["console", "apns"]).default("console"),
  APNS_KEY_ID: z.string().optional(),
  APNS_TEAM_ID: z.string().optional(),
  // Contents of the AuthKey_XXXX.p8 file. Literal "\n" sequences are accepted.
  APNS_KEY_P8: z.string().optional(),

  // local: in-process timers saved to DATA_DIR. eventbridge: one-shot EventBridge Scheduler schedules.
  SCHEDULER: z.enum(["local", "eventbridge"]).default("local"),
  SCHEDULER_GROUP: z.string().optional(),
  SCHEDULER_ROLE_ARN: z.string().optional(),
  // The worker Lambda that timers invoke.
  WORKER_FUNCTION_ARN: z.string().optional(),

  // fake: offline heuristics. anthropic: Claude API (ANTHROPIC_API_KEY). bedrock: Claude on Amazon Bedrock.
  AI_PROVIDER: z.enum(["fake", "anthropic", "bedrock"]).default("fake"),
  // Defaults to claude-opus-5-5 (anthropic.claude-opus-5-5 on Bedrock).
  AI_MODEL: z.string().optional(),
  // hash: offline feature hashing. titan: Titan Text Embeddings v2 on Bedrock.
  EMBED_PROVIDER: z.enum(["hash", "titan"]).default("hash"),

  // fake: funding confirms instantly, payouts are simulated. stripe: PaymentIntents + Connect transfers.
  PAYMENTS_PROVIDER: z.enum(["fake", "stripe"]).default("fake"),
  STRIPE_SECRET_KEY: z.string().optional(),
  STRIPE_PUBLISHABLE_KEY: z.string().optional(),
  STRIPE_WEBHOOK_SECRET: z.string().optional(),

  // local: files under DATA_DIR/blobs served by this API. s3: presigned S3 URLs.
  BLOBS: z.enum(["local", "s3"]).default("local"),
  BUCKET: z.string().optional(),
});

export type Env = z.infer<typeof schema>;

export interface Config extends Omit<Env, "JWT_SECRET" | "SCHEDULER_GROUP"> {
  JWT_SECRET: string;
  SCHEDULER_GROUP: string;
  rules: Rules;
  tables: { jobs: string; users: string; offers: string; proofs: string; ledger: string; kv: string };
  adminUserIds: Set<string>;
}

const LOCAL_JWT_SECRET = "local-dev-secret-do-not-use-in-production!!";

export function loadConfig(env: NodeJS.ProcessEnv = process.env): Config {
  const parsed = schema.safeParse(env);
  if (!parsed.success) {
    const problems = parsed.error.issues.map((i) => `${i.path.join(".")}: ${i.message}`).join("; ");
    throw new Error(`Invalid configuration: ${problems}`);
  }
  const e = parsed.data;
  if (!e.JWT_SECRET && e.STAGE !== "local") throw new Error("Invalid configuration: JWT_SECRET is required outside local dev");
  const table = (name: string, override?: string) => override ?? `bounty-${e.STAGE}-${name}`;
  return {
    ...e,
    JWT_SECRET: e.JWT_SECRET ?? LOCAL_JWT_SECRET,
    SCHEDULER_GROUP: e.SCHEDULER_GROUP ?? `bounty-${e.STAGE}`,
    adminUserIds: new Set(e.ADMIN_USER_IDS.split(",").map((s) => s.trim()).filter(Boolean)),
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
