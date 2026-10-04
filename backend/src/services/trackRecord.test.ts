import assert from "node:assert/strict";
import { test } from "node:test";
import type { Twin } from "../domain/types.js";
import { creditSkills } from "./trackRecord.js";

const NOW = "2026-10-04T15:00:00Z";
const twin = (skills: Twin["skills"]): Twin => ({ skills, summary: "", yearsExperience: 0, roles: [], education: [], certifications: [], ingest: { status: "idle", sources: [], updatedAt: NOW }, updatedAt: NOW }) as unknown as Twin;
const skill = (name: string, confidence: number, extra: Partial<Twin["skills"][number]> = {}) => ({
  normName: name.toLowerCase(), name, level: 3, confidence, sources: [{ kind: "linkedin" as const, evidence: "Designer" }], userEdited: false, deleted: false, ...extra,
});

test("a strong rating raises the skill, records the job and cites the review", () => {
  const next = creditSkills(twin([skill("Flyer design", 0.6)]), { skills: [{ name: "Flyer design", category: "design", verdict: "strong", evidence: "looked professional" }] }, { title: "Lost cat flyer", stars: 5 }, NOW);
  const s = next.skills[0]!;
  assert.equal(Math.round(s.confidence * 100), 72, "moves 30% of the way toward 1");
  assert.deepEqual(s.record, { jobs: 1, starsSum: 5, lastAt: NOW });
  assert.match(s.sources.at(-1)!.evidence, /5★ for "Lost cat flyer": looked professional/);
  assert.equal(s.sources[0]!.kind, "linkedin", "earlier sources are kept");
});

test("a weak rating lowers a listed skill but never adds one", () => {
  const next = creditSkills(
    twin([skill("Lawn mowing", 0.9)]),
    { skills: [{ name: "Lawn mowing", category: "yard work", verdict: "weak", evidence: "missed half the yard" }, { name: "Edging", category: "yard work", verdict: "weak", evidence: "" }] },
    { title: "Mow my lawn", stars: 2 },
    NOW,
  );
  assert.equal(next.skills.length, 1);
  assert.ok(Math.abs(next.skills[0]!.confidence - 0.705) < 1e-9, "moves 30% of the way toward 0.25");
});

test("one review nudges, a consistent record promotes, and deletions are respected", () => {
  let t = twin([skill("Tutoring", 0.5), skill("Calligraphy", 0.9, { deleted: true })]);
  for (let i = 0; i < 5; i++) {
    t = creditSkills(t, { skills: [{ name: "Tutoring", category: "tutoring", verdict: "strong", evidence: "clear" }, { name: "Calligraphy", category: "design", verdict: "strong", evidence: "" }] }, { title: `Session ${i}`, stars: 5 }, NOW);
  }
  const tutoring = t.skills.find((s) => s.normName === "tutoring")!;
  assert.equal(tutoring.level, 5, "five 5-star jobs make it an expert skill");
  assert.ok(tutoring.confidence < 1 && tutoring.confidence > 0.9);
  assert.equal(tutoring.sources.filter((s) => s.kind === "rating").length, 5);
  assert.equal(t.skills.find((s) => s.normName === "calligraphy")?.record, undefined, "a deleted skill stays out of it");
});

test("a new skill the job proved is added from a good rating", () => {
  const next = creditSkills(twin([]), { skills: [{ name: "Event photography", category: "photography", verdict: "strong", evidence: "great shots" }] }, { title: "Club photos", stars: 5 }, NOW);
  assert.equal(next.skills[0]?.name, "Event photography");
  assert.equal(next.skills[0]?.record?.jobs, 1);
});
