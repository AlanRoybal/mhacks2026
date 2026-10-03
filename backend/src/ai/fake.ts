// Deterministic stand-in for Claude. Used when AI_PROVIDER=fake (local dev without keys, tests) and,
// for the checklist and ranking tasks, as the fallback when Claude is unavailable.

import type { Category } from "../domain/types.js";
import type { Ai, ChecklistDraft, GradeInput, GradeResult, JobBrief, ProfileExtraction, ProfileInput, RerankCandidate, RerankPick } from "./ai.js";

type DraftItem = ChecklistDraft["items"][number];

const TEMPLATES: Record<Category, { minutes: number; items: DraftItem[] }> = {
  design: {
    minutes: 30,
    items: [
      { text: "The finished design is fully visible and legible", evidence: "photo", required: true, angleHint: "Straight on, whole design in frame" },
      { text: "The design follows the brief in the job description", evidence: "photo", required: true, angleHint: "" },
      { text: "A digital copy of the design is attached", evidence: "file", required: false, angleHint: "" },
    ],
  },
  home: {
    minutes: 60,
    items: [
      { text: "Before and after photos of the work area from the same angle", evidence: "photo_pair", required: true, angleHint: "Whole work area in frame" },
      { text: "Close-up showing the finished result", evidence: "photo", required: true, angleHint: "Close enough to see detail" },
      { text: "Checked in at the job location", evidence: "location", required: true, angleHint: "" },
    ],
  },
  tutoring: {
    minutes: 60,
    items: [
      { text: "Summary of the topics covered in the session", evidence: "text", required: true, angleHint: "" },
      { text: "Worksheet, notes or solutions from the session", evidence: "file", required: false, angleHint: "" },
    ],
  },
  photography: {
    minutes: 60,
    items: [
      { text: "Delivered photos at full resolution", evidence: "file", required: true, angleHint: "" },
      { text: "A photo taken at the shoot location", evidence: "photo", required: false, angleHint: "Show the subject and setting" },
    ],
  },
  technology: {
    minutes: 90,
    items: [
      { text: "Link to the delivered work (repository, site or shared file)", evidence: "link", required: true, angleHint: "" },
      { text: "Short description of what was done and how to check it", evidence: "text", required: true, angleHint: "" },
    ],
  },
  errands: {
    minutes: 30,
    items: [
      { text: "Photo showing the errand completed (item delivered or task done)", evidence: "photo", required: true, angleHint: "Show the item and where it was left" },
      { text: "Checked in at the job location", evidence: "location", required: true, angleHint: "" },
    ],
  },
  other: {
    minutes: 45,
    items: [
      { text: "Photo showing the finished task", evidence: "photo", required: true, angleHint: "Whole result in frame" },
      { text: "Short note describing what was done", evidence: "text", required: false, angleHint: "" },
    ],
  },
};

const RISKY = /\b(gun|firearm|weapon|drugs?|cocaine|password|ssn|social security|bank account|nude|escort|fake id)\b/i;

const words = (s: string) => new Set(s.toLowerCase().match(/[a-z]{3,}/g) ?? []);

export function templateChecklist(job: JobBrief): ChecklistDraft {
  const template = TEMPLATES[job.category];
  let items = template.items;
  if (job.remote) {
    items = items.filter((i) => i.evidence !== "location").map((i) => (i.evidence === "photo_pair" ? { ...i, evidence: "photo" as const } : i));
  } else if (!items.some((i) => i.evidence === "location")) {
    items = [...items, { text: "Checked in at the job location", evidence: "location", required: true, angleHint: "" }];
  }
  const flags = RISKY.test(`${job.title} ${job.description}`) ? ["Mentions restricted items or personal data; review before posting"] : [];
  return { items, estMinutes: template.minutes, flags };
}

export function heuristicRerank(job: JobBrief, candidates: RerankCandidate[]): RerankPick[] {
  const jobWords = words(`${job.title} ${job.description} ${job.category}`);
  return [...candidates]
    .sort((a, b) => b.score - a.score)
    .map((c) => {
      const matching = c.skills.find((skill) => [...words(skill)].some((w) => jobWords.has(w))) ?? c.skills[0];
      return {
        workerId: c.workerId,
        fit: Math.round(Math.min(1, Math.max(0, c.score)) * 100),
        why: matching ? `Your ${matching} fits this job`.slice(0, 90) : "Your twin thinks this job fits your profile",
        estMinutes: job.estMinutes ?? 30,
      };
    });
}

function linkedinSkills(text: string): string[] {
  const section = text.split(/^## /m).find((part) => part.startsWith("Skills.csv"));
  if (!section) return [];
  return section
    .split("\n")
    .slice(2)
    .map((line) => line.split(",")[0]?.replace(/^"|"$/g, "").trim() ?? "")
    .filter(Boolean)
    .slice(0, 25);
}

export class FakeAi implements Ai {
  readonly name = "fake";

  async extractProfile(input: ProfileInput): Promise<ProfileExtraction> {
    const fromCsv = input.text ? linkedinSkills(input.text) : [];
    const names = fromCsv.length > 0 ? fromCsv : ["Graphic design", "Illustration", "Product photography"];
    const evidence = fromCsv.length > 0 ? "Listed in LinkedIn Skills.csv" : "Sample skill (AI_PROVIDER=fake does not read PDFs)";
    return {
      summary: "Profile created by the offline extractor. Edit your skills to make it accurate.",
      yearsExperience: 0,
      skills: names.map((name) => ({ name, category: "other", level: 3, confidence: 0.6, evidence })),
      roles: [],
      education: [],
      certifications: [],
    };
  }

  async generateChecklist(job: JobBrief): Promise<ChecklistDraft> {
    return templateChecklist(job);
  }

  async rerank(job: JobBrief, candidates: RerankCandidate[]): Promise<RerankPick[]> {
    return heuristicRerank(job, candidates);
  }

  // Passes every item that has evidence. Only for local dev: it never looks at the photos.
  async grade(input: GradeInput): Promise<GradeResult> {
    const covered = new Set(input.evidence.map((e) => e.itemId));
    return {
      codeVisible: true,
      codeReadAs: input.challengeCode,
      items: input.checklist.map((item) => ({
        itemId: item.id,
        verdict: covered.has(item.id) || !item.required ? "pass" : "fail",
        confidence: 0.9,
        reason: covered.has(item.id) ? "Evidence submitted (offline grader)" : "No evidence submitted",
      })),
      posterSummary: "Checked by the offline grader, which does not inspect photos.",
      workerFeedback: "",
      model: "fake",
    };
  }
}
