import type Anthropic from "@anthropic-ai/sdk";
import { betaZodOutputFormat } from "@anthropic-ai/sdk/helpers/beta/zod";
import type { BetaContentBlockParam } from "@anthropic-ai/sdk/resources/beta/messages/messages";
import type { z } from "zod";
import { formatUsd } from "../domain/money.js";
import type { Logger } from "../lib/log.js";
import {
  AiUnavailableError,
  ChecklistDraft,
  GradeResult,
  ProfileExtraction,
  RerankResult,
  type Ai,
  type GradeInput,
  type JobBrief,
  type ProfileInput,
  type RerankCandidate,
  type RerankPick,
} from "./ai.js";
import { CHECKLIST, EXTRACT_PROFILE, gradePrompt, RERANK } from "./prompts.js";

type Effort = "low" | "medium" | "high";

// Both Anthropic and AnthropicBedrockMantle expose the same beta messages API.
export interface MessagesClient {
  beta: { messages: Anthropic["beta"]["messages"] };
}

interface CallOptions<T extends z.ZodType> {
  task: string;
  system: string;
  content: BetaContentBlockParam[];
  schema: T;
  effort: Effort;
  maxTokens: number;
  timeoutMs: number;
  // Request-path calls use 0 so a slow model falls back instead of outlasting the API Gateway timeout.
  maxRetries?: number;
}

const tag = (name: string, body: string) => `<${name}>\n${body}\n</${name}>`;

function jobText(job: JobBrief): string {
  return tag(
    "job",
    [
      `Title: ${job.title}`,
      `Category: ${job.category}`,
      `Where: ${job.remote ? "remote" : "in person"}`,
      `Pay: ${formatUsd(job.bountyCents)}`,
      job.estMinutes ? `Estimated minutes: ${job.estMinutes}` : "",
      `Description: ${job.description}`,
    ]
      .filter(Boolean)
      .join("\n"),
  );
}

export class ClaudeAi implements Ai {
  readonly name: string;

  constructor(
    private readonly client: MessagesClient,
    private readonly model: string,
    private readonly log: Logger,
    // Server-side refusal fallbacks exist on the Claude API only (not Bedrock).
    private readonly serverFallbacks: boolean,
  ) {
    this.name = model;
  }

  private async call<T extends z.ZodType>(o: CallOptions<T>): Promise<z.infer<T>> {
    const started = Date.now();
    const response = await this.client.beta.messages.parse(
      {
        model: this.model,
        max_tokens: o.maxTokens,
        system: o.system,
        messages: [{ role: "user", content: o.content }],
        output_config: { effort: o.effort, format: betaZodOutputFormat(o.schema) },
        ...(this.serverFallbacks ? { betas: ["server-side-fallback-2026-07-01"], fallbacks: "default" as const } : {}),
      },
      { timeout: o.timeoutMs, maxRetries: o.maxRetries ?? 1 },
    );
    this.log.info("AI call", {
      task: o.task,
      ms: Date.now() - started,
      stop: response.stop_reason,
      inputTokens: response.usage.input_tokens,
      outputTokens: response.usage.output_tokens,
    });
    if (response.stop_reason === "refusal") throw new AiUnavailableError(o.task, "the model declined");
    if (!response.parsed_output) throw new AiUnavailableError(o.task, `no parseable output (stop: ${response.stop_reason})`);
    return response.parsed_output;
  }

  async extractProfile(input: ProfileInput): Promise<ProfileExtraction> {
    const label = input.kind === "linkedin_zip" ? "LinkedIn data export" : input.kind === "linkedin_pdf" ? "LinkedIn profile PDF" : "résumé";
    const content: BetaContentBlockParam[] = [];
    if (input.pdf) content.push({ type: "document", source: { type: "base64", media_type: "application/pdf", data: input.pdf.toString("base64") } });
    if (input.text) content.push({ type: "text", text: tag("linkedin_export", input.text) });
    content.push({ type: "text", text: `Build the worker profile from this ${label}.` });
    return this.call({ task: "extract_profile", system: EXTRACT_PROFILE, content, schema: ProfileExtraction, effort: "medium", maxTokens: 8000, timeoutMs: 90_000 });
  }

  async generateChecklist(job: JobBrief): Promise<ChecklistDraft> {
    return this.call({
      task: "checklist",
      system: CHECKLIST,
      content: [{ type: "text", text: `${jobText(job)}\n\nWrite the acceptance checklist.` }],
      schema: ChecklistDraft,
      effort: "low",
      maxTokens: 3000,
      // Runs inside POST /jobs (29 s API Gateway limit); on timeout the category template is used.
      timeoutMs: 12_000,
      maxRetries: 0,
    });
  }

  async rerank(job: JobBrief, candidates: RerankCandidate[]): Promise<RerankPick[]> {
    const list = candidates
      .map((c) =>
        tag(
          "candidate",
          [
            `workerId: ${c.workerId}`,
            `Skills: ${c.skills.join("; ") || "none listed"}`,
            `Summary: ${c.summary || "none"}`,
            c.distanceKm === undefined ? "" : `Distance: ${c.distanceKm.toFixed(1)} km`,
            `Reliability: ${Math.round(c.reliability * 100)}%`,
          ]
            .filter(Boolean)
            .join("\n"),
        ),
      )
      .join("\n");
    const result = await this.call({
      task: "rerank",
      system: RERANK,
      content: [{ type: "text", text: `${jobText(job)}\n\n${list}\n\nRank the candidates.` }],
      schema: RerankResult,
      effort: "low",
      maxTokens: 3000,
      timeoutMs: 20_000,
    });
    return result.picks;
  }

  async grade(input: GradeInput): Promise<GradeResult> {
    const content: BetaContentBlockParam[] = [{ type: "text", text: jobText(input.job) }];
    content.push({
      type: "text",
      text: tag(
        "checklist",
        input.checklist
          .map((i) => {
            const kind = i.evidenceType === "PHOTO" ? `PHOTO x${i.photoCount ?? 1}${i.beforeAfter ? ", before/after" : ""}` : i.evidenceType;
            return `${i.id} [${kind}${i.required ? ", required" : ""}]: ${i.text}`;
          })
          .join("\n"),
      ),
    });
    for (const e of input.evidence) {
      const header = `Evidence for item ${e.itemId} (${e.phase}, ${e.kind})${e.note ? ` — ${e.note}` : ""}:`;
      content.push({ type: "text", text: header });
      if (e.image) {
        content.push({ type: "image", source: { type: "base64", media_type: e.image.mediaType, data: e.image.base64 } });
      }
      if (e.url) content.push({ type: "text", text: tag("link", e.url) });
      if (e.text) content.push({ type: "text", text: tag("worker_text", e.text) });
    }
    content.push({ type: "text", text: "Grade every checklist item." });
    const result = await this.call({
      task: "grade",
      system: gradePrompt(input.challengeCode),
      content,
      schema: GradeResult,
      effort: "medium",
      maxTokens: 6000,
      timeoutMs: 120_000,
    });
    return { ...result, model: this.model };
  }
}
