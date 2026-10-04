// Proof of work: server-side evidence checks (US-39) and submission (US-41).
//
// Blocking problems (the app must fix them before submitting): a required item has no evidence,
// an upload is missing or too large, a photo wasn't taken with the Bounty camera for this job, a photo
// predates the start of the job, or a photo was already used as proof before. Location problems are warnings: they are shown to the grader and the
// poster, and a CHECK_IN item outside the job site fails grading.

import { MAX_FILE_BYTES, MAX_PHOTO_BYTES, MAX_VIDEO_BYTES } from "../blobs/index.js";
import type { Deps } from "../deps.js";
import { haversineKm } from "../domain/geo.js";
import { newId } from "../domain/ids.js";
import type { EvidenceItem, Job, Proof, ProofChecks, User } from "../domain/types.js";
import { conflict, forbidden } from "../lib/errors.js";
import { verifyCapture, sha256Hex } from "./capture.js";
import { applyEvent, getJobOrThrow } from "./jobs.js";

// Photos may be stamped a little before the server clock says the job started (device clock skew).
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
  const notCapturedInApp: string[] = [];
  const warnings: string[] = [];

  // 1. Uploads exist and fit, and get a fingerprint (MD5 ETag). One photo may cover several items of
  //    the same job, but a photo already used as proof for another job is rejected.
  for (const e of items) {
    if (!e.blobKey) continue;
    const info = await deps.blobs.head(e.blobKey);
    const limit = e.kind === "photo" ? MAX_PHOTO_BYTES : e.kind === "video" ? MAX_VIDEO_BYTES : MAX_FILE_BYTES;
    if (!info || info.size > limit) {
      missingUploads.push(e.checklistItemId);
      continue;
    }
    e.etag = info.etag;
    e.contentType = info.contentType ?? e.contentType;
    const usedBy = await deps.store.kvGet<{ jobId: string }>(`etag:${info.etag}`);
    if (usedBy && usedBy.jobId !== job.jobId) duplicates.push(e.checklistItemId);
    // Photos and videos must come from the Bounty camera: the app's signature has to match these exact bytes.
    if ((e.kind === "photo" || e.kind === "video") && !(await capturedInApp(deps, job, e))) notCapturedInApp.push(e.checklistItemId);
  }

  // 2. Coverage, counting distinct uploaded images: the same image can't fill two photo slots or be
  //    both the "before" and the "after". A video of the item covers it on its own (its frames don't
  //    count as separate photos).
  for (const item of job.checklist) {
    const evidence = items.filter((e) => e.checklistItemId === item.id);
    const uploadedPhotos = evidence.filter((e) => e.kind === "photo" && e.etag && !e.frameOf);
    const before = new Set(uploadedPhotos.filter((p) => p.phase === "before").map((p) => p.etag));
    const after = new Set(uploadedPhotos.filter((p) => p.phase !== "before").map((p) => p.etag));
    const videos = evidence.filter((e) => e.kind === "video" && e.etag);
    const videoBefore = videos.some((v) => v.phase === "before");
    const videoAfter = videos.some((v) => v.phase !== "before");
    let covered: boolean;
    switch (item.evidenceType) {
      case "PHOTO":
        covered = (videoAfter || after.size >= (item.photoCount ?? 1)) && (!item.beforeAfter || videoBefore || before.size >= 1);
        if ([...before].some((etag) => after.has(etag))) duplicates.push(item.id);
        break;
      case "CHECK_IN":
        covered = evidence.some((e) => e.kind === "location");
        break;
      case "LINK":
        covered = evidence.some((e) => e.kind === "link" && Boolean(e.url));
        break;
      case "FILE":
        covered = evidence.some((e) => (e.kind === "file" || e.kind === "photo" || e.kind === "video") && e.etag);
        break;
    }
    if (item.required && !covered) missingRequired.push(item.id);
  }

  // 3. Time and place: photos and check-ins after the worker started, at the job.
  const issuedAt = Date.parse(job.capture?.issuedAt ?? job.startedAt ?? "");
  for (const e of items) {
    if (e.kind === "photo" || e.kind === "video" || e.kind === "location") {
      const at = Date.parse(e.capturedAt ?? "");
      if (!Number.isFinite(at) || at < issuedAt - CLOCK_SKEW_MS || at > now + CLOCK_SKEW_MS) outsideTimeWindow.push(e.checklistItemId);
    }
    // A video's frames share its time and place, so they aren't checked twice.
    if (!job.remote && job.location && ((e.kind === "photo" && !e.frameOf) || e.kind === "video" || e.kind === "location")) {
      const limit = e.kind === "location" ? deps.config.rules.checkInRadiusM : photoGeofenceM(deps);
      if (e.lat === undefined || e.lng === undefined) {
        warnings.push(`${e.checklistItemId}: no GPS on ${e.kind === "location" ? "the check-in" : `a ${e.kind}`}`);
        outsideGeofence.push(e.checklistItemId);
      } else {
        const meters = Math.round(haversineKm({ lat: e.lat, lng: e.lng }, job.location) * 1000);
        if (meters > limit) {
          warnings.push(`${e.checklistItemId}: ${e.kind === "location" ? "check-in" : e.kind} taken ${meters} m from the job`);
          outsideGeofence.push(e.checklistItemId);
        }
      }
    }
  }

  const uniq = (xs: string[]) => [...new Set(xs)];
  const checks = {
    missingRequired: uniq(missingRequired),
    outsideTimeWindow: uniq(outsideTimeWindow),
    outsideGeofence: uniq(outsideGeofence),
    duplicates: uniq(duplicates),
    missingUploads: uniq(missingUploads),
    notCapturedInApp: uniq(notCapturedInApp),
    warnings,
  };
  const ok =
    checks.missingRequired.length + checks.outsideTimeWindow.length + checks.duplicates.length + checks.missingUploads.length + checks.notCapturedInApp.length === 0;
  return { ok, ...checks };
}

async function capturedInApp(deps: Deps, job: Job, e: EvidenceItem): Promise<boolean> {
  if (!job.capture || !e.blobKey || !e.sha256 || !e.signature || !e.capturedAt) return false;
  const bytes = await deps.blobs.get(e.blobKey);
  if (!bytes || sha256Hex(bytes) !== e.sha256.toLowerCase()) return false;
  return verifyCapture(job.capture.key, { jobId: job.jobId, sha256: e.sha256, capturedAt: e.capturedAt, lat: e.lat, lng: e.lng }, e.signature);
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
    checks: {
      ok: checks.ok,
      missingRequired: checks.missingRequired,
      outsideTimeWindow: checks.outsideTimeWindow,
      outsideGeofence: checks.outsideGeofence,
      duplicates: checks.duplicates,
      missingUploads: checks.missingUploads,
      notCapturedInApp: checks.notCapturedInApp,
    },
    createdAt: deps.now().toISOString(),
  };
  if (!checks.ok) return { job, proof, checks };
  // A double tap must not submit twice (it would use up a retry or leave an orphan proof).
  const claimed = await deps.store.kvPut(`submit:${jobId}:${job.failedAttempts}`, proof.proofId, { ifAbsent: true, ttlSeconds: 30 });
  if (!claimed) throw conflict("already_submitted", "This proof is already being submitted");
  await deps.store.putProof(proof);
  // Photos become unusable as proof for any other job.
  for (const e of items) if (e.etag) await deps.store.kvPut(`etag:${e.etag}`, { jobId, proofId: proof.proofId }, { ifAbsent: true });
  const next = await applyEvent(deps, jobId, { type: "SUBMIT", proofId: proof.proofId }, { kind: "user", userId: user.userId });
  return { job: next, proof, checks };
}
