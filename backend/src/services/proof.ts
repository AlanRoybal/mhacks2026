// Proof of work: server-side evidence checks (US-39) and submission (US-41).
//
// Blocking problems (the app must fix them before submitting): a required item has no evidence,
// an upload is missing or too large, a photo predates the one-time code, or a photo was already
// used as proof before. Location problems are warnings: they are shown to the grader and the
// poster, and a CHECK_IN item outside the job site fails grading.

import { MAX_FILE_BYTES, MAX_PHOTO_BYTES } from "../blobs/index.js";
import type { Deps } from "../deps.js";
import { haversineKm } from "../domain/geo.js";
import { newId } from "../domain/ids.js";
import type { EvidenceItem, Job, Proof, ProofChecks, User } from "../domain/types.js";
import { conflict, forbidden } from "../lib/errors.js";
import { applyEvent, getJobOrThrow } from "./jobs.js";

// Photos may be taken a little before the server clock says the code was issued (device clock skew).
const CLOCK_SKEW_MS = 2 * 60_000;

export interface Checks extends ProofChecks {
  warnings: string[];
}

export function photoGeofenceM(deps: Deps): number {
  return deps.config.rules.checkInRadiusM * 2;
}

export async function checkEvidence(deps: Deps, job: Job, items: EvidenceItem[]): Promise<Checks> {
  const now = deps.now().getTime();
  const missingRequired: string[] = [];
  const outsideTimeWindow: string[] = [];
  const outsideGeofence: string[] = [];
  const duplicates: string[] = [];
  const missingUploads: string[] = [];
  const warnings: string[] = [];

  for (const item of job.checklist) {
    const evidence = items.filter((e) => e.checklistItemId === item.id);
    const photos = evidence.filter((e) => e.kind === "photo");
    let covered: boolean;
    switch (item.evidenceType) {
      case "PHOTO": {
        const after = photos.filter((p) => p.phase !== "before").length;
        const before = photos.filter((p) => p.phase === "before").length;
        covered = after >= (item.photoCount ?? 1) && (!item.beforeAfter || before >= 1);
        break;
      }
      case "CHECK_IN":
        covered = evidence.some((e) => e.kind === "location");
        break;
      case "LINK":
        covered = evidence.some((e) => e.kind === "link" && Boolean(e.url));
        break;
      case "FILE":
        covered = evidence.some((e) => e.kind === "file" || e.kind === "photo");
        break;
    }
    if (item.required && !covered) missingRequired.push(item.id);
  }

  const issuedAt = Date.parse(job.challenge?.issuedAt ?? "");
  for (const e of items) {
    if (e.kind === "photo" || e.kind === "location") {
      const at = Date.parse(e.capturedAt ?? "");
      if (!Number.isFinite(at) || at < issuedAt - CLOCK_SKEW_MS || at > now + CLOCK_SKEW_MS) outsideTimeWindow.push(e.checklistItemId);
    }
    if (!job.remote && job.location && (e.kind === "photo" || e.kind === "location")) {
      const limit = e.kind === "location" ? deps.config.rules.checkInRadiusM : photoGeofenceM(deps);
      if (e.lat === undefined || e.lng === undefined) {
        warnings.push(`${e.checklistItemId}: no GPS on ${e.kind === "location" ? "the check-in" : "a photo"}`);
        outsideGeofence.push(e.checklistItemId);
      } else {
        const meters = Math.round(haversineKm({ lat: e.lat, lng: e.lng }, job.location) * 1000);
        if (meters > limit) {
          warnings.push(`${e.checklistItemId}: ${e.kind === "location" ? "check-in" : "photo"} taken ${meters} m from the job`);
          outsideGeofence.push(e.checklistItemId);
        }
      }
    }
    if (e.blobKey) {
      const info = await deps.blobs.head(e.blobKey);
      const limit = e.kind === "photo" ? MAX_PHOTO_BYTES : MAX_FILE_BYTES;
      if (!info || info.size > limit) {
        missingUploads.push(e.checklistItemId);
        continue;
      }
      e.etag = info.etag;
      e.contentType = info.contentType ?? e.contentType;
      // One photo may cover several items of the same job; reuse across jobs is not allowed.
      const usedBy = await deps.store.kvGet<{ jobId: string }>(`etag:${info.etag}`);
      if (usedBy && usedBy.jobId !== job.jobId) duplicates.push(e.checklistItemId);
    }
  }

  const uniq = (xs: string[]) => [...new Set(xs)];
  const checks = {
    missingRequired: uniq(missingRequired),
    outsideTimeWindow: uniq(outsideTimeWindow),
    outsideGeofence: uniq(outsideGeofence),
    duplicates: uniq(duplicates),
    missingUploads: uniq(missingUploads),
    warnings,
  };
  const ok = checks.missingRequired.length + checks.outsideTimeWindow.length + checks.duplicates.length + checks.missingUploads.length === 0;
  return { ok, ...checks };
}

export function requireWorker(job: Job, user: User): void {
  if (job.workerId !== user.userId) throw forbidden("Only the assigned worker can submit proof");
  if (job.state !== "IN_PROGRESS") throw conflict("invalid_transition", `Proof can't be submitted while the job is ${job.state}`);
}

export async function submitProof(deps: Deps, user: User, jobId: string, items: EvidenceItem[]): Promise<{ job: Job; proof: Proof; checks: Checks }> {
  const job = await getJobOrThrow(deps, jobId);
  requireWorker(job, user);
  const checks = await checkEvidence(deps, job, items);
  const proof: Proof = {
    jobId,
    proofId: newId(deps.now().getTime()),
    workerId: user.userId,
    attempt: job.failedAttempts + 1,
    items,
    checks: { ok: checks.ok, missingRequired: checks.missingRequired, outsideTimeWindow: checks.outsideTimeWindow, outsideGeofence: checks.outsideGeofence, duplicates: checks.duplicates, missingUploads: checks.missingUploads },
    createdAt: deps.now().toISOString(),
  };
  if (!checks.ok) return { job, proof, checks };
  await deps.store.putProof(proof);
  // Photos become unusable as proof for any other job.
  for (const e of items) if (e.etag) await deps.store.kvPut(`etag:${e.etag}`, { jobId, proofId: proof.proofId }, { ifAbsent: true });
  const next = await applyEvent(deps, jobId, { type: "SUBMIT", proofId: proof.proofId }, { kind: "user", userId: user.userId });
  return { job: next, proof, checks };
}
