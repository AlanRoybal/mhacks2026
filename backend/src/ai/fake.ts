// Deterministic stand-in for Claude. Used when AI_PROVIDER=fake (local dev without keys, tests) and,
// for the checklist and ranking tasks, as the fallback when Claude is unavailable.

import type { Category } from "../domain/types.js";
import type { Ai, ChecklistDraft, GradeInput, GradeResult, RatingInput, RatingInsight, JobBrief, ProfileExtraction, ProfileInput, RerankCandidate, RerankPick } from "./ai.js";

type DraftItem = ChecklistDraft["items"][number];

const photo = (text: string, angleHint: string, opts: { photoCount?: number; beforeAfter?: boolean; required?: boolean } = {}): DraftItem => ({
  text,
  evidenceType: "PHOTO",
  photoCount: opts.photoCount ?? 1,
  beforeAfter: opts.beforeAfter ?? false,
  required: opts.required ?? true,
  angleHint,
});
const other = (evidenceType: "CHECK_IN" | "LINK" | "FILE", text: string, required = true): DraftItem => ({
  text,
  evidenceType,
  photoCount: 0,
  beforeAfter: false,
  required,
  angleHint: "",
});
const CHECK_IN = other("CHECK_IN", "Checked in at the job location");

const TEMPLATES: Record<Category, { minutes: number; items: DraftItem[] }> = {
  DESIGN: {
    minutes: 30,
    items: [
      photo("The finished design is fully visible and legible", "Straight on, whole design in frame"),
      photo("The design follows the brief in the job description", "Close enough to read any text"),
      other("FILE", "A digital copy of the design is attached", false),
    ],
  },
  HOME: {
    minutes: 60,
    items: [
      photo("The work area is visibly finished compared to before", "Whole work area in frame", { beforeAfter: true }),
      photo("Close-up showing the finished result", "Close enough to see detail"),
      CHECK_IN,
    ],
  },
  YARD_WORK: {
    minutes: 60,
    items: [
      photo("The whole area is done to an even standard", "From the edge of the yard, whole area in frame", { photoCount: 2, beforeAfter: true }),
      photo("Clippings and debris are cleared from paths and driveway", "Show the paths and driveway"),
      CHECK_IN,
    ],
  },
  MOVING: {
    minutes: 60,
    items: [
      photo("The items are in their new location", "Show the items in the destination room", { photoCount: 2 }),
      photo("Nothing is visibly damaged", "Close-up of the moved items"),
      CHECK_IN,
    ],
  },
  TUTORING: {
    minutes: 60,
    items: [other("LINK", "Session notes or a recording link"), other("FILE", "Worksheet or solutions from the session", false)],
  },
  PHOTOGRAPHY: {
    minutes: 60,
    items: [other("FILE", "Delivered photos at full resolution"), photo("A photo taken at the shoot location", "Show the subject and setting", { required: false })],
  },
  TECHNOLOGY: {
    minutes: 90,
    items: [other("LINK", "Link to the delivered work (repository, site or shared file)"), other("FILE", "Short write-up of what was done and how to check it")],
  },
  ERRANDS: {
    minutes: 30,
    items: [photo("The errand is complete (item delivered or task done)", "Show the item and where it was left"), CHECK_IN],
  },
  OTHER: {
    minutes: 45,
    items: [photo("Photo showing the finished task", "Whole result in frame"), other("FILE", "Anything else that shows the work was done", false)],
  },
};

const RISKY = /\b(gun|firearm|weapon|drugs?|cocaine|password|ssn|social security|bank account|nude|escort|fake id)\b/i;

const words = (s: string) => new Set(s.toLowerCase().match(/[a-z]{3,}/g) ?? []);

export function templateChecklist(job: JobBrief): ChecklistDraft {
  const template = TEMPLATES[job.category];
  let items = template.items;
  if (job.remote) {
    items = items.filter((i) => i.evidenceType !== "CHECK_IN").map((i) => ({ ...i, beforeAfter: false }));
  } else if (!items.some((i) => i.evidenceType === "CHECK_IN")) {
    items = [...items, CHECK_IN];
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

  async assessRating(input: RatingInput): Promise<RatingInsight> {
    return fakeRatingInsight(input);
  }
}

const CATEGORY_SKILL: Record<Category, { name: string; category: string }> = {
  DESIGN: { name: "Graphic design", category: "design" },
  HOME: { name: "Home repair", category: "home" },
  YARD_WORK: { name: "Yard work", category: "yard work" },
  MOVING: { name: "Moving help", category: "moving" },
  TUTORING: { name: "Tutoring", category: "tutoring" },
  PHOTOGRAPHY: { name: "Photography", category: "photography" },
  TECHNOLOGY: { name: "Tech help", category: "technology" },
  ERRANDS: { name: "Errands", category: "errands" },
  OTHER: { name: "General help", category: "other" },
};

// Offline: credit the worker's existing skill that the job's title mentions, or the job's category,
// with a verdict straight from the stars.
export function fakeRatingInsight(input: RatingInput): RatingInsight {
  const verdict = input.stars >= 4 ? "strong" : input.stars === 3 ? "adequate" : "weak";
  const words = `${input.job.title} ${input.job.description}`.toLowerCase();
  const existing = input.workerSkills.find((s) => s.toLowerCase().split(/\s+/).some((w) => w.length > 3 && words.includes(w)));
  const fallback = CATEGORY_SKILL[input.job.category];
  const evidence = input.comment?.trim() ? `${input.stars} stars: "${input.comment.trim().slice(0, 60)}"` : `${input.stars} stars from the poster`;
  return { skills: [{ name: existing ?? fallback.name, category: fallback.category, verdict, evidence }] };
}
