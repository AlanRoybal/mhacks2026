// Wraps Claude so a model outage or refusal never blocks a job:
// - checklist: falls back to the category template (the poster can still edit it)
// - rerank: falls back to the deterministic score order
// - grade: falls back to "unclear" on every item, which sends the decision to the poster
// - profile extraction: no fallback; the import is marked failed and the user retries (US-03)
// - job thread: falls back to the template twin (passes questions on to the worker)

import type { Logger } from "../lib/log.js";
import type { Ai, ChecklistDraft, GradeInput, GradeResult, JobBrief, ProfileExtraction, ProfileInput, RerankCandidate, RerankPick, ThreadInput, ThreadTurn } from "./ai.js";
import { fakeThreadTurn, heuristicRerank, templateChecklist } from "./fake.js";

export class ResilientAi implements Ai {
  readonly name: string;

  constructor(
    private readonly inner: Ai,
    private readonly log: Logger,
  ) {
    this.name = inner.name;
  }

  extractProfile(input: ProfileInput): Promise<ProfileExtraction> {
    return this.inner.extractProfile(input);
  }

  async generateChecklist(job: JobBrief): Promise<ChecklistDraft> {
    try {
      return await this.inner.generateChecklist(job);
    } catch (error) {
      this.log.warn("Checklist AI failed; using template", { error });
      return templateChecklist(job);
    }
  }

  async rerank(job: JobBrief, candidates: RerankCandidate[]): Promise<RerankPick[]> {
    try {
      return await this.inner.rerank(job, candidates);
    } catch (error) {
      this.log.warn("Rerank AI failed; using score order", { error });
      return heuristicRerank(job, candidates);
    }
  }

  async grade(input: GradeInput): Promise<GradeResult> {
    try {
      return await this.inner.grade(input);
    } catch (error) {
      this.log.warn("Grading AI failed; sending to the poster", { error });
      return {
        items: input.checklist.map((item) => ({ itemId: item.id, verdict: "unclear", confidence: 0, reason: "Automatic review was unavailable" })),
        posterSummary: "Automatic review was unavailable. Please check the evidence yourself.",
        workerFeedback: "",
        model: "unavailable",
      };
    }
  }

  async threadTurn(input: ThreadInput): Promise<ThreadTurn> {
    try {
      return await this.inner.threadTurn(input);
    } catch (error) {
      this.log.warn("Thread AI failed; using template twin", { error });
      return fakeThreadTurn(input);
    }
  }
}
