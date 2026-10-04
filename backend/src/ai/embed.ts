// Text embeddings for matching twins to jobs.
// - titan: Amazon Titan Text Embeddings v2 on Bedrock (1024-d, normalized).
// - hash: feature-hashed bag of words and bigrams. No network, deterministic, decent on keyword overlap.

import { BedrockRuntimeClient, InvokeModelCommand } from "@aws-sdk/client-bedrock-runtime";
import { createHash } from "node:crypto";

export interface Embedder {
  readonly model: string;
  embed(text: string): Promise<number[]>;
}

const STOPWORDS = new Set("the and for with that this from your you are was were will have has into about over a an of to in on at by or as is it be".split(" "));

function normalize(v: number[]): number[] {
  const norm = Math.sqrt(v.reduce((s, x) => s + x * x, 0));
  return norm === 0 ? v : v.map((x) => x / norm);
}

export class HashEmbedder implements Embedder {
  readonly model: string;

  constructor(private readonly dims = 512) {
    this.model = `hash-${dims}-v1`;
  }

  async embed(text: string): Promise<number[]> {
    const tokens = (text.toLowerCase().match(/[a-z0-9+#]+/g) ?? []).filter((t) => t.length > 1 && !STOPWORDS.has(t));
    // Crude stemming so "design", "designs" and "designer" share a bucket.
    const stems = tokens.map((t) => t.replace(/(ing|ers|er|es|s)$/, ""));
    const features = [...stems, ...stems.slice(1).map((t, i) => `${stems[i]}_${t}`)];
    const v = new Array<number>(this.dims).fill(0);
    for (const f of features) {
      const h = createHash("sha1").update(f).digest();
      const index = h.readUInt32BE(0) % this.dims;
      v[index] = (v[index] ?? 0) + ((h[4] ?? 0) & 1 ? 1 : -1);
    }
    return normalize(v);
  }
}

export class TitanEmbedder implements Embedder {
  readonly model = "titan-embed-text-v2-1024";
  private readonly client: BedrockRuntimeClient;

  constructor(region: string) {
    this.client = new BedrockRuntimeClient({ region });
  }

  async embed(text: string): Promise<number[]> {
    const response = await this.client.send(
      new InvokeModelCommand({
        modelId: "amazon.titan-embed-text-v2:0",
        contentType: "application/json",
        accept: "application/json",
        body: JSON.stringify({ inputText: text.slice(0, 20_000), dimensions: 1024, normalize: true }),
      }),
    );
    const { embedding } = JSON.parse(new TextDecoder().decode(response.body)) as { embedding: number[] };
    return embedding;
  }
}

export function cosine(a: number[], b: number[]): number {
  if (a.length !== b.length || a.length === 0) return 0;
  let dot = 0;
  let na = 0;
  let nb = 0;
  for (let i = 0; i < a.length; i++) {
    const x = a[i] ?? 0;
    const y = b[i] ?? 0;
    dot += x * y;
    na += x * x;
    nb += y * y;
  }
  return na === 0 || nb === 0 ? 0 : dot / Math.sqrt(na * nb);
}
