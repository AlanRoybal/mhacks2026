// The four AI tasks. Implementations: ClaudeAi (Anthropic API or Bedrock) and FakeAi (deterministic,
// no network: local dev, tests, and the fallback when Claude is unavailable).

import { z } from "zod";
import type { Category, ChecklistItem, Education, EvidencePhase, ItemVerdict, Role } from "../domain/types.js";

export const SkillExtraction = z.object({
  name: z.string(),
  category: z.string(),
  level: z.number(),
  confidence: z.number(),
  evidence: z.string(),
});

export const ProfileExtraction = z.object({
  summary: z.string(),
  yearsExperience: z.number(),
  skills: z.array(SkillExtraction),
  roles: z.array(z.object({ title: z.string(), org: z.string(), start: z.string(), end: z.string(), summary: z.string() })),
  education: z.array(z.object({ school: z.string(), degree: z.string(), field: z.string(), end: z.string() })),
  certifications: z.array(z.string()),
});
export type ProfileExtraction = z.infer<typeof ProfileExtraction>;

export const ChecklistDraft = z.object({
  items: z.array(
    z.object({
      text: z.string(),
      evidenceType: z.enum(["PHOTO", "CHECK_IN", "LINK", "FILE"]),
      photoCount: z.number(),
      beforeAfter: z.boolean(),
      required: z.boolean(),
      angleHint: z.string(),
    }),
  ),
  estMinutes: z.number(),
  // Reasons a human should look at this job before it goes live (illegal, dangerous, adult, personal data).
  flags: z.array(z.string()),
});
export type ChecklistDraft = z.infer<typeof ChecklistDraft>;

export const RerankResult = z.object({
  picks: z.array(z.object({ workerId: z.string(), fit: z.number(), why: z.string(), estMinutes: z.number() })),
});
export type RerankPick = z.infer<typeof RerankResult>["picks"][number];

export const GradeResult = z.object({
  codeVisible: z.boolean(),
  codeReadAs: z.string(),
  items: z.array(z.object({ itemId: z.string(), verdict: z.enum(["pass", "fail", "unclear"]), confidence: z.number(), reason: z.string() })),
  posterSummary: z.string(),
  workerFeedback: z.string(),
});
export type GradeResult = z.infer<typeof GradeResult> & { model: string };

// One turn of the job thread: what the worker's twin texts the poster.
export const ThreadTurn = z.object({
  // The text to send the poster. Plain, under 320 characters.
  reply: z.string(),
  // A question only the worker can answer, to pass on in the app. "" when none.
  forWorker: z.string(),
  // A fact the poster gave that the worker should see on the job (access, parking, preferences). "" when none.
  detail: z.string(),
});
export type ThreadTurn = z.infer<typeof ThreadTurn>;

export interface ThreadInput {
  // open: the first text after the worker accepts. reply: answer the poster's latest text.
  mode: "open" | "reply";
  job: JobBrief;
  checklist: string[];
  workerName: string;
  // Where the job stands, e.g. "Accepted 10 minutes ago, not started yet".
  status: string;
  // Facts already collected from the poster.
  details: string[];
  history: { from: "twin" | "poster" | "worker"; text: string }[];
  message?: string;
}

export type ProfileSourceKind = "resume_pdf" | "linkedin_pdf" | "linkedin_zip" | "gmail_sent";

export interface ProfileInput {
  kind: ProfileSourceKind;
  pdf?: Buffer;
  // Extracted CSV text for a LinkedIn export ZIP, or sent-mail text for Gmail.
  text?: string;
}

export interface JobBrief {
  title: string;
  description: string;
  category: Category;
  remote: boolean;
  bountyCents: number;
  estMinutes?: number;
}

export interface RerankCandidate {
  workerId: string;
  summary: string;
  // Top skills with their source, e.g. "Logo design (LinkedIn)".
  skills: string[];
  distanceKm?: number;
  reliability: number;
  // Pre-ranking score from embeddings, reliability and distance (0-1). Used by the fallback ranker.
  score: number;
}

export interface GradeEvidence {
  itemId: string;
  phase: EvidencePhase;
  kind: "photo" | "link" | "file" | "location";
  // The app uploads JPEG; Claude does not read HEIC.
  image?: { mediaType: "image/jpeg" | "image/png" | "image/webp" | "image/gif"; base64: string };
  url?: string;
  text?: string;
  note?: string;
}

export interface GradeInput {
  job: JobBrief;
  checklist: ChecklistItem[];
  challengeCode: string;
  evidence: GradeEvidence[];
}

export interface Ai {
  readonly name: string;
  extractProfile(input: ProfileInput): Promise<ProfileExtraction>;
  generateChecklist(job: JobBrief): Promise<ChecklistDraft>;
  rerank(job: JobBrief, candidates: RerankCandidate[]): Promise<RerankPick[]>;
  grade(input: GradeInput): Promise<GradeResult>;
  threadTurn(input: ThreadInput): Promise<ThreadTurn>;
}

export class AiUnavailableError extends Error {
  constructor(task: string, reason: string) {
    super(`AI ${task} unavailable: ${reason}`);
    this.name = "AiUnavailableError";
  }
}

// Helpers to turn model output into domain records.
export const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, Number.isFinite(n) ? n : lo));
export const blankToUndefined = (s: string) => (s.trim() ? s.trim() : undefined);

export function toRoles(roles: ProfileExtraction["roles"]): Role[] {
  return roles.map((r) => ({
    title: r.title,
    org: blankToUndefined(r.org),
    start: blankToUndefined(r.start),
    end: blankToUndefined(r.end),
    summary: blankToUndefined(r.summary),
  }));
}

export function toEducation(education: ProfileExtraction["education"]): Education[] {
  return education.map((e) => ({ school: e.school, degree: blankToUndefined(e.degree), field: blankToUndefined(e.field), end: blankToUndefined(e.end) }));
}

export type { ItemVerdict };
