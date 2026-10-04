// The digital twin: skills with sources and confidence, built from imports and user edits.

import { unzipSync } from "fflate";
import { AiUnavailableError, clamp, toEducation, toRoles, type ProfileExtraction, type ProfileSourceKind } from "../ai/index.js";
import type { Deps } from "../deps.js";
import type { Skill, SkillSourceKind, Twin, User } from "../domain/types.js";
import type { Task } from "../tasks/tasks.js";
import { updateUser } from "./users.js";

const MAX_SKILLS = 60;
const LINKEDIN_FILES = new Set(["Skills.csv", "Positions.csv", "Education.csv", "Certifications.csv", "Profile.csv", "Projects.csv", "Courses.csv"]);
const MAX_CSV_CHARS = 20_000;
// Real LinkedIn CSVs are a few KB. The cap stops a small "zip bomb" from expanding to gigabytes.
const MAX_CSV_BYTES = 1_000_000;

export const SOURCE_FOR: Record<ProfileSourceKind, SkillSourceKind> = { resume_pdf: "resume", linkedin_pdf: "linkedin", linkedin_zip: "linkedin" };

export const normName = (name: string) => name.trim().toLowerCase().replace(/\s+/g, " ");

export const activeSkills = (twin: Twin) => twin.skills.filter((s) => !s.deleted).sort((a, b) => b.confidence - a.confidence);

// Imports add skills and sources. They never override a user edit and never bring back a deleted skill.
export function mergeExtraction(twin: Twin, ex: ProfileExtraction, source: SkillSourceKind, now: string): Twin {
  const skills = new Map(twin.skills.map((s) => [s.normName, structuredClone(s)]));
  for (const x of ex.skills) {
    const key = normName(x.name);
    if (!key) continue;
    const level = clamp(Math.round(x.level), 1, 5);
    const confidence = clamp(x.confidence, 0, 1);
    const evidence = x.evidence.trim().slice(0, 160);
    const existing = skills.get(key);
    if (!existing) {
      skills.set(key, {
        normName: key,
        name: x.name.trim(),
        category: x.category.trim() || undefined,
        level,
        confidence,
        sources: [{ kind: source, evidence }],
        userEdited: false,
        deleted: false,
      });
      continue;
    }
    if (existing.deleted) continue;
    if (!existing.sources.some((s) => s.kind === source && s.evidence === evidence)) existing.sources.push({ kind: source, evidence });
    existing.confidence = Math.max(existing.confidence, confidence);
    if (!existing.userEdited) existing.level = Math.max(existing.level, level);
  }
  // User-edited skills and tombstones always stay; imported skills fill the rest by confidence.
  const merged = [...skills.values()];
  const pinned = merged.filter((s) => s.deleted || s.userEdited);
  const room = Math.max(0, MAX_SKILLS - pinned.filter((s) => !s.deleted).length);
  const imported = merged
    .filter((s) => !s.deleted && !s.userEdited)
    .sort((a, b) => b.confidence - a.confidence)
    .slice(0, room);
  return {
    ...twin,
    skills: [...pinned, ...imported],
    summary: ex.summary.trim() || twin.summary,
    roles: ex.roles.length > 0 ? toRoles(ex.roles) : twin.roles,
    education: ex.education.length > 0 ? toEducation(ex.education) : twin.education,
    certifications: [...new Set([...twin.certifications, ...ex.certifications.map((c) => c.trim()).filter(Boolean)])],
    yearsExperience: Math.max(twin.yearsExperience, clamp(ex.yearsExperience, 0, 70)),
    updatedAt: now,
  };
}

// Adds or edits a skill by hand. Also how a user restores a skill they deleted.
export function upsertSkill(twin: Twin, input: { name: string; level?: number; category?: string }, now: string): Twin {
  const key = normName(input.name);
  const skills = twin.skills.map((s) => structuredClone(s));
  const existing = skills.find((s) => s.normName === key);
  if (existing) {
    existing.name = input.name.trim();
    existing.deleted = false;
    existing.userEdited = true;
    if (input.level !== undefined) existing.level = input.level;
    if (input.category !== undefined) existing.category = input.category;
    if (!existing.sources.some((s) => s.kind === "user")) existing.sources.push({ kind: "user", evidence: "Added by you" });
  } else {
    const skill: Skill = {
      normName: key,
      name: input.name.trim(),
      category: input.category,
      level: input.level ?? 3,
      confidence: 1,
      sources: [{ kind: "user", evidence: "Added by you" }],
      userEdited: true,
      deleted: false,
    };
    skills.push(skill);
  }
  return { ...twin, skills, updatedAt: now };
}

// Makes the active skills exactly `skills` (TwinKit sends the whole edited list). Skills left out are
// tombstoned; listed ones are kept with their sources, renamed or re-weighted as the user edited them.
export function replaceSkills(twin: Twin, skills: { name: string; confidence?: number }[], now: string): Twin {
  const wanted = new Map(skills.map((s) => [normName(s.name), s]));
  const next = twin.skills.map((s) => structuredClone(s));
  for (const skill of next) {
    const edit = wanted.get(skill.normName);
    if (!edit) {
      if (!skill.deleted) Object.assign(skill, { deleted: true, userEdited: true });
      continue;
    }
    const confidence = clamp(edit.confidence ?? skill.confidence, 0, 1);
    if (skill.deleted || skill.name !== edit.name.trim() || skill.confidence !== confidence) {
      Object.assign(skill, { name: edit.name.trim(), confidence, deleted: false, userEdited: true });
    }
    wanted.delete(skill.normName);
  }
  for (const [key, s] of wanted) {
    if (!key) continue;
    next.push({
      normName: key,
      name: s.name.trim(),
      level: 3,
      confidence: clamp(s.confidence ?? 1, 0, 1),
      sources: [{ kind: "user", evidence: "Added by you" }],
      userEdited: true,
      deleted: false,
    });
  }
  return { ...twin, skills: next, updatedAt: now };
}

export function deleteSkill(twin: Twin, key: string, now: string): Twin | null {
  const skills = twin.skills.map((s) => structuredClone(s));
  const skill = skills.find((s) => s.normName === key && !s.deleted);
  if (!skill) return null;
  skill.deleted = true;
  skill.userEdited = true;
  return { ...twin, skills, updatedAt: now };
}

// The text that gets embedded for matching.
export function twinDocument(user: User): string {
  const t = user.twin;
  const skills = activeSkills(t)
    .slice(0, 30)
    .map((s) => (s.category ? `${s.name} (${s.category})` : s.name));
  return [
    t.summary,
    `Skills: ${skills.join(", ")}`,
    t.roles.length ? `Roles: ${t.roles.map((r) => (r.org ? `${r.title} at ${r.org}` : r.title)).join("; ")}` : "",
    t.certifications.length ? `Certifications: ${t.certifications.join(", ")}` : "",
  ]
    .filter(Boolean)
    .join("\n");
}

export async function refreshEmbedding(deps: Deps, userId: string): Promise<User> {
  const user = await deps.store.getUser(userId);
  if (!user) throw new Error(`User ${userId} not found`);
  const hasSkills = activeSkills(user.twin).length > 0;
  const embedding = hasSkills ? await deps.embedder.embed(twinDocument(user)) : undefined;
  return updateUser(deps, userId, (u) => {
    u.twin.embedding = embedding;
    u.twin.embeddingModel = hasSkills ? deps.embedder.model : undefined;
  });
}

// What still blocks matching ("missing") and what would improve it ("recommended").
export function readiness(user: User, opts: { payoutsRequired: boolean }) {
  const missing: string[] = [];
  const recommended: string[] = [];
  if (activeSkills(user.twin).length === 0) missing.push("skills");
  if (user.devices.length === 0) missing.push("notifications");
  if (opts.payoutsRequired && !user.payouts.stripeTransfersEnabled) missing.push("payouts");
  if (user.prefs.inPersonOk && !user.prefs.base) recommended.push("location");
  if (!user.availability) recommended.push("availability");
  return { ready: missing.length === 0, missing, recommended };
}

export function linkedinZipText(bytes: Buffer): string {
  let files: Record<string, Uint8Array>;
  try {
    files = unzipSync(new Uint8Array(bytes), {
      filter: (f) => LINKEDIN_FILES.has(f.name.split("/").pop() ?? "") && f.originalSize <= MAX_CSV_BYTES,
    });
  } catch {
    throw new IngestError("That file isn't a valid ZIP. Upload the ZIP LinkedIn emailed you.");
  }
  const parts = Object.entries(files).map(([name, data]) => `## ${name.split("/").pop()}\n${new TextDecoder().decode(data).slice(0, MAX_CSV_CHARS)}`);
  if (parts.length === 0) throw new IngestError("That ZIP doesn't look like a LinkedIn data export (no Skills.csv or Positions.csv).");
  return parts.join("\n\n");
}

export class IngestError extends Error {}

export async function ingestProfile(deps: Deps, task: Extract<Task, { name: "ingest_profile" }>): Promise<void> {
  const now = () => deps.now().toISOString();
  try {
    const bytes = await deps.blobs.get(task.blobKey);
    if (!bytes) throw new IngestError("The upload wasn't found. Try uploading again.");
    const input = task.sourceKind === "linkedin_zip" ? { kind: task.sourceKind, text: linkedinZipText(bytes) } : { kind: task.sourceKind, pdf: bytes };
    const extraction = await deps.ai.extractProfile(input);
    await updateUser(deps, task.userId, (u) => {
      u.twin = mergeExtraction(u.twin, extraction, SOURCE_FOR[task.sourceKind], now());
      u.twin.ingest = { status: "done", sources: [...new Set([...u.twin.ingest.sources, task.sourceKind])], updatedAt: now() };
    });
    await refreshEmbedding(deps, task.userId);
    deps.log.info("Profile imported", { userId: task.userId, source: task.sourceKind, skills: extraction.skills.length });
  } catch (error) {
    deps.log.warn("Profile import failed", { userId: task.userId, error });
    const message =
      error instanceof IngestError
        ? error.message
        : error instanceof AiUnavailableError
          ? "We couldn't read that file. Try another file or add skills by hand."
          : "Import failed. Please try again.";
    await updateUser(deps, task.userId, (u) => {
      u.twin.ingest = { ...u.twin.ingest, status: "failed", error: message, updatedAt: now() };
    });
  }
}
