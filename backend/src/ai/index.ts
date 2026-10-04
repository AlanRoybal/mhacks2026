import Anthropic from "@anthropic-ai/sdk";
import { AnthropicBedrock, AnthropicBedrockMantle } from "@anthropic-ai/bedrock-sdk";
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
    case "bedrock": {
      // Uses the Lambda role (or your AWS profile) for SigV4.
      const model = config.AI_MODEL ?? `anthropic.${DEFAULT_MODEL}`;
      // Mantle serves only the newest models; inference-profile IDs (us.anthropic.claude-opus-4-5-...) need the InvokeModel client.
      const profile = /^(us|eu|apac|global)\./.test(model);
      const client = profile ? new AnthropicBedrock({ awsRegion: config.AWS_REGION }) : new AnthropicBedrockMantle({ awsRegion: config.AWS_REGION });
      return new ResilientAi(new ClaudeAi(client, model, log, false, profile), log);
    }
  }
}

export function createEmbedder(config: Config): Embedder {
  return config.EMBED_PROVIDER === "titan" ? new TitanEmbedder(config.AWS_REGION) : new HashEmbedder();
}

export * from "./ai.js";
export { cosine, type Embedder } from "./embed.js";
