// Track record: what posters' ratings say about each of a worker's skills, the way a rideshare rating
// says how a driver actually drives. After a poster rates a finished job, Claude reads the job, the
// stars and the comment and names the skills the job exercised with a verdict for each; this code
// decides how much each skill's confidence moves, so one review can nudge a profile but not rewrite it.
//
// A skill backed by rated jobs carries `record` (jobs, stars) and a "rating" source. Matching and the
// re-ranker show that record, so a worker proven at flyer design is offered flyer jobs first.

import { clamp, type RatingInsight } from "../ai/index.js";
import type { Deps } from "../deps.js";
import type { Skill, Twin } from "../domain/types.js";
import { briefOf } from "./postings.js";
import { activeSkills, normName, refreshEmbedding } from "./twin.js";
import { updateUser } from "./users.js";

// How far one rating moves a skill's confidence toward its target (an exponential moving average).
const LEARNING_RATE = 0.3;
const TARGET = { strong: 1, adequate: 0.75, weak: 0.25 } as const;
const MAX_SKILLS_PER_RATING = 4;
const MAX_RATING_SOURCES = 5;

export interface RatedJob {
  title: string;
  stars: number;
}

export const averageStars = (skill: Skill): number | null =>
  skill.record && skill.record.jobs > 0 ? Math.round((skill.record.starsSum / skill.record.jobs) * 10) / 10 : null;

// Pure: applies one rating's verdicts to the twin. Deleted skills stay deleted; a weak verdict never
// adds a skill the worker didn't already list.
export function creditSkills(twin: Twin, insight: RatingInsight, rated: RatedJob, now: string): Twin {
  const skills = twin.skills.map((s) => structuredClone(s));
  const seen = new Set<string>();
  for (const verdict of insight.skills.slice(0, MAX_SKILLS_PER_RATING)) {
    const key = normName(verdict.name);
    if (!key || seen.has(key)) continue;
    seen.add(key);
    let skill = skills.find((s) => s.normName === key);
    if (skill?.deleted) continue;
    if (!skill) {
      if (verdict.verdict === "weak") continue;
      skill = {
        normName: key,
        name: verdict.name.trim(),
        category: verdict.category.trim() || undefined,
        level: 3,
        confidence: 0.5,
        sources: [],
        userEdited: false,
        deleted: false,
      };
      skills.push(skill);
    }
    skill.confidence = clamp(skill.confidence + LEARNING_RATE * (TARGET[verdict.verdict] - skill.confidence), 0.05, 1);
    const record = skill.record ?? { jobs: 0, starsSum: 0, lastAt: now };
    skill.record = { jobs: record.jobs + 1, starsSum: record.starsSum + rated.stars, lastAt: now };
    // A consistent record of top ratings is worth more than a résumé line.
    const avg = skill.record.starsSum / skill.record.jobs;
    if (verdict.verdict === "strong" && skill.record.jobs >= 2 && avg >= 4.5) skill.level = Math.max(skill.level, 4);
    if (verdict.verdict === "strong" && skill.record.jobs >= 5 && avg >= 4.7) skill.level = 5;
    const evidence = `${rated.stars}★ for "${rated.title.slice(0, 40)}": ${verdict.evidence.trim().slice(0, 80)}`;
    const ratingSources = [...skill.sources.filter((s) => s.kind === "rating"), { kind: "rating" as const, evidence }].slice(-MAX_RATING_SOURCES);
    skill.sources = [...skill.sources.filter((s) => s.kind !== "rating"), ...ratingSources];
  }
  return { ...twin, skills, updatedAt: now };
}

// The "learn" effect's task. Runs once per job: a retried task finds the claim and stops.
export async function learnFromRating(deps: Deps, jobId: string): Promise<void> {
  const job = await deps.store.getJob(jobId);
  const rating = job?.ratings.byPoster;
  if (!job || !job.workerId || !rating) return;
  const worker = await deps.store.getUser(job.workerId);
  if (!worker) return;
  if (!(await deps.store.kvPut(`learned:${jobId}`, true, { ifAbsent: true }))) return;

  const proof = job.latestProofId ? await deps.store.getProof(jobId, job.latestProofId) : null;
  const insight = await deps.ai.assessRating({
    job: briefOf(job),
    checklist: job.checklist.map((i) => i.text),
    stars: rating.stars,
    comment: rating.comment,
    gradeSummary: proof?.grade?.posterSummary,
    workerSkills: activeSkills(worker.twin).map((s) => s.name),
  });
  const now = deps.now().toISOString();
  await updateUser(deps, worker.userId, (u) => {
    u.twin = creditSkills(u.twin, insight, { title: job.title, stars: rating.stars }, now);
  });
  await refreshEmbedding(deps, worker.userId);
  deps.log.info("Learned from rating", { jobId, workerId: worker.userId, stars: rating.stars, skills: insight.skills.map((s) => `${s.name}:${s.verdict}`) });
}
