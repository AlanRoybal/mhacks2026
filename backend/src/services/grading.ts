// The "grade" effect. Claude looks at the evidence; this code makes the decision (AI authority is a
// recommendation, product rule 9):
//   fail    any required item fails with confidence >= 0.7
//   pass    every required item passes with confidence >= 0.7, the one-time code was seen in a photo,
//           and no location warnings
//   unclear anything else -> the poster decides; nothing auto-releases
// CHECK_IN items are verified by the server from GPS, not by the model.

import type { GradeEvidence, GradeResult } from "../ai/index.js";
import type { Deps } from "../deps.js";
import { haversineKm } from "../domain/geo.js";
import type { Grade, GradeDecision, ItemVerdict, Job, Proof } from "../domain/types.js";
import { applyEvent } from "./jobs.js";
import { briefOf } from "./postings.js";

const CONFIDENT = 0.7;
const READABLE_IMAGES = new Set(["image/jpeg", "image/png", "image/webp", "image/gif"]);

async function evidenceFor(deps: Deps, job: Job, proof: Proof): Promise<GradeEvidence[]> {
  const out: GradeEvidence[] = [];
  for (const e of proof.items) {
    const base = { itemId: e.checklistItemId, phase: e.phase, kind: e.kind, note: e.note } as const;
    if ((e.kind === "photo" || e.kind === "file") && e.blobKey) {
      const type = e.contentType ?? "";
      if (READABLE_IMAGES.has(type)) {
        const bytes = await deps.blobs.get(e.blobKey);
        if (bytes) out.push({ ...base, image: { mediaType: type as "image/jpeg", base64: bytes.toString("base64") } });
        continue;
      }
      out.push({ ...base, text: `A ${type || "file"} was uploaded; it cannot be shown here.` });
      continue;
    }
    if (e.kind === "link") out.push({ ...base, url: e.url });
    if (e.kind === "location" && job.location && e.lat !== undefined && e.lng !== undefined) {
      const meters = Math.round(haversineKm({ lat: e.lat, lng: e.lng }, job.location) * 1000);
      out.push({ ...base, text: `Checked in ${meters} m from the job at ${e.capturedAt ?? "unknown time"}.` });
    }
  }
  return out;
}

function checkInVerdict(deps: Deps, job: Job, proof: Proof, itemId: string): ItemVerdict {
  const checkIn = proof.items.find((e) => e.checklistItemId === itemId && e.kind === "location");
  if (!checkIn || checkIn.lat === undefined || checkIn.lng === undefined || !job.location) {
    return { itemId, verdict: "fail", confidence: 1, reason: "No on-site check-in with GPS" };
  }
  const meters = Math.round(haversineKm({ lat: checkIn.lat, lng: checkIn.lng }, job.location) * 1000);
  return meters <= deps.config.rules.checkInRadiusM
    ? { itemId, verdict: "pass", confidence: 1, reason: `Checked in ${meters} m from the job` }
    : { itemId, verdict: "fail", confidence: 1, reason: `Checked in ${meters} m from the job (limit ${deps.config.rules.checkInRadiusM} m)` };
}

export function decide(job: Job, proof: Proof, verdicts: ItemVerdict[], codeVisible: boolean): { decision: GradeDecision; because: string } {
  // If no photo/link/file item is marked required (older drafts), all of them must pass.
  const evidence = job.checklist.filter((i) => i.evidenceType !== "CHECK_IN");
  const required = [...job.checklist.filter((i) => i.required), ...(evidence.some((i) => i.required) ? [] : evidence)];
  const byId = new Map(verdicts.map((v) => [v.itemId, v]));
  const failed = required.filter((i) => byId.get(i.id)?.verdict === "fail" && (byId.get(i.id)?.confidence ?? 0) >= CONFIDENT);
  if (failed.length > 0) return { decision: "fail", because: `Failed: ${failed.map((i) => i.id).join(", ")}` };
  const unsure = required.filter((i) => byId.get(i.id)?.verdict !== "pass" || (byId.get(i.id)?.confidence ?? 0) < CONFIDENT);
  if (unsure.length > 0) return { decision: "unclear", because: `Not confident about: ${unsure.map((i) => i.id).join(", ")}` };
  const hasPhotos = proof.items.some((e) => e.kind === "photo");
  if (hasPhotos && !codeVisible) return { decision: "unclear", because: "The one-time code was not visible in any photo" };
  if (proof.checks.outsideGeofence.length > 0) return { decision: "unclear", because: "Some evidence was captured away from the job" };
  return { decision: "pass", because: "Every required item passed" };
}

export async function gradeProof(deps: Deps, jobId: string, proofId: string): Promise<void> {
  const [job, proof] = await Promise.all([deps.store.getJob(jobId), deps.store.getProof(jobId, proofId)]);
  if (!job || !proof || job.state !== "SUBMITTED" || job.latestProofId !== proofId) return;

  let grade = proof.grade;
  if (!grade) {
    const result: GradeResult = await deps.ai.grade({
      job: briefOf(job),
      checklist: job.checklist.filter((i) => i.evidenceType !== "CHECK_IN"),
      challengeCode: job.challenge?.code ?? "",
      evidence: await evidenceFor(deps, job, proof),
    });
    const items = job.checklist.map(
      (item): ItemVerdict =>
        item.evidenceType === "CHECK_IN"
          ? checkInVerdict(deps, job, proof, item.id)
          : (result.items.find((v) => v.itemId === item.id) ?? { itemId: item.id, verdict: "unclear", confidence: 0, reason: "Not graded" }),
    );
    const { decision, because } = decide(job, proof, items, result.codeVisible);
    grade = {
      decision,
      decidedBecause: because,
      codeVisible: result.codeVisible,
      codeReadAs: result.codeReadAs,
      items,
      posterSummary: result.posterSummary,
      workerFeedback: result.workerFeedback,
      model: result.model,
    } satisfies Grade;
    await deps.store.putProof({ ...proof, grade, gradedAt: deps.now().toISOString() });
    deps.log.info("Proof graded", { jobId, proofId, decision, because });
  }
  await applyEvent(deps, jobId, { type: "GRADED", proofId, decision: grade.decision, summary: grade.posterSummary || grade.decidedBecause }, { kind: "system", source: "grader" });
}
