import Anthropic from "@anthropic-ai/sdk";
import { AnthropicBedrockMantle } from "@anthropic-ai/bedrock-sdk";
import type { Config } from "../config.js";
import type { Logger } from "../lib/log.js";
import type { Ai } from "./ai.js";
import { ClaudeAi } from "./claude.js";
import { HashEmbedder, TitanEmbedder, type Embedder } from "./embed.js";
import { FakeAi } from "./fake.js";
import { ResilientAi } from "./resilient.js";

const DEFAULT_MODEL = "claude-opus-5-5";

export function createAi(config: Config, log: Logger): Ai {
  switch (config.AI_PROVIDER) {
    case "fake":
      return new FakeAi();
    case "anthropic":
      // Reads ANTHROPIC_API_KEY (or an `ant auth login` profile).
      return new ResilientAi(new ClaudeAi(new Anthropic(), config.AI_MODEL ?? DEFAULT_MODEL, log, true), log);
    case "bedrock":
      // Uses the Lambda role (or your AWS profile) for SigV4.
      return new ResilientAi(new ClaudeAi(new AnthropicBedrockMantle({ awsRegion: config.AWS_REGION }), config.AI_MODEL ?? `anthropic.${DEFAULT_MODEL}`, log, false), log);
  }
}

export function createEmbedder(config: Config): Embedder {
  return config.EMBED_PROVIDER === "titan" ? new TitanEmbedder(config.AWS_REGION) : new HashEmbedder();
}

export * from "./ai.js";
export { cosine, type Embedder } from "./embed.js";
