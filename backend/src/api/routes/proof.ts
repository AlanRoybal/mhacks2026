import { Hono, type Context } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import type { EvidenceItem, Job, User } from "../../domain/types.js";
import { badRequest } from "../../lib/errors.js";
import { getJobOrThrow } from "../../services/jobs.js";
import { checkEvidence, requireWorker, submitProof } from "../../services/proof.js";
import { isAdmin } from "../auth.js";
import { errorBody, parseBody, type AppEnv } from "../http.js";
import { jobWire, proofWire, verdictsWire, WireContext } from "../wire.js";
import { visibleJob } from "./jobs.js";
import { ownedUploadKey } from "./uploads.js";

const FileRef = z.object({ fileURL: z.string().optional(), blobKey: z.string().optional() });
// Signed by the app right after it captured the file (services/capture.ts).
const InAppCapture = {
  sha256: z.string().regex(/^[0-9a-fA-F]{64}$/).optional(),
  signature: z.string().max(200).optional(),
};
const Photo = FileRef.extend({
  // "before" photos are taken at the start of before/after items; everything else is the result.
  phase: z.enum(["before", "after"]).optional(),
  // The capture time as the app signed it, so it is kept exactly as sent.
  capturedAt: z.string().datetime({ offset: true }),
  latitude: z.number().min(-90).max(90).optional(),
  longitude: z.number().min(-180).max(180).optional(),
  ...InAppCapture,
});
// A short in-app video, with a few stills the app pulled from it (each signed like a photo).
const Video = Photo.extend({
  frames: z.array(FileRef.extend(InAppCapture)).min(1).max(4),
});
const ProofItemIn = z.object({
  checklistItemId: z.string(),
  photos: z.array(Photo).max(10).optional(),
  videos: z.array(Video).max(3).optional(),
  link: z.string().url().optional(),
  files: z.array(FileRef).max(5).optional(),
  checkIn: z.object({ latitude: z.number(), longitude: z.number(), at: z.string().datetime({ offset: true }) }).optional(),
  note: z.string().max(500).optional(),
});
const ProofBody = z.object({ items: z.array(ProofItemIn).min(1).max(20) });

function toEvidence(deps: Deps, user: User, job: Job, body: z.infer<typeof ProofBody>): EvidenceItem[] {
  const out: EvidenceItem[] = [];
  for (const item of body.items) {
    const checklistItem = job.checklist.find((i) => i.id === item.checklistItemId);
    if (!checklistItem) throw badRequest(`Unknown checklist item ${item.checklistItemId}`);
    const start = out.length;
    for (const p of item.photos ?? []) {
      out.push({
        checklistItemId: item.checklistItemId,
        kind: "photo",
        phase: p.phase ?? (checklistItem.beforeAfter ? "after" : "single"),
        blobKey: ownedUploadKey(deps, user.userId, p),
        capturedAt: new Date(p.capturedAt).toISOString(),
        lat: p.latitude,
        lng: p.longitude,
        sha256: p.sha256,
        signature: p.signature,
      });
    }
    for (const v of item.videos ?? []) {
      const capture = {
        checklistItemId: item.checklistItemId,
        phase: v.phase ?? (checklistItem.beforeAfter ? "after" : "single"),
        capturedAt: new Date(v.capturedAt).toISOString(),
        lat: v.latitude,
        lng: v.longitude,
      } as const;
      const videoKey = ownedUploadKey(deps, user.userId, v);
      out.push({ ...capture, kind: "video", blobKey: videoKey, sha256: v.sha256, signature: v.signature });
      for (const f of v.frames) {
        out.push({ ...capture, kind: "photo", blobKey: ownedUploadKey(deps, user.userId, f), sha256: f.sha256, signature: f.signature, frameOf: videoKey });
      }
    }
    for (const f of item.files ?? []) out.push({ checklistItemId: item.checklistItemId, kind: "file", phase: "single", blobKey: ownedUploadKey(deps, user.userId, f) });
    if (item.link) out.push({ checklistItemId: item.checklistItemId, kind: "link", phase: "single", url: item.link });
    if (item.checkIn) {
      out.push({
        checklistItemId: item.checklistItemId,
        kind: "location",
        phase: "single",
        lat: item.checkIn.latitude,
        lng: item.checkIn.longitude,
        capturedAt: new Date(item.checkIn.at).toISOString(),
      });
    }
    const first = out[start];
    if (item.note && first) first.note = item.note;
  }
  return out;
}

export function proofRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  // US-39: run the server checks without submitting, so the app can show what is still missing.
  app.post("/:id/proof/precheck", async (c) => {
    const user = c.get("user");
    const job = await getJobOrThrow(deps, c.req.param("id"));
    requireWorker(job, user);
    const body = await parseBody(c, ProofBody);
    return c.json({ checks: await checkEvidence(deps, job, toEvidence(deps, user, job, body)) });
  });

  // US-41: submit for AI review. 422 proof_incomplete (with checks) if something blocking is missing.
  const submit = async (c: Context<AppEnv>) => {
    const user = c.get("user");
    const jobId = c.req.param("id") ?? "";
    const job = await getJobOrThrow(deps, jobId);
    requireWorker(job, user);
    const body = await parseBody(c, ProofBody);
    const result = await submitProof(deps, user, jobId, toEvidence(deps, user, job, body));
    if (!result.checks.ok) {
      return c.json(errorBody("proof_incomplete", "Some evidence is missing or invalid", { checks: result.checks }), 422);
    }
    return c.json(await jobWire(new WireContext(deps), result.job, user));
  };
  app.post("/:id/proof", submit);
  app.post("/:id/proof/submit", submit);

  // Every submission for the job, newest first, with the AI's per-item results (US-42/45).
  app.get("/:id/proofs", async (c) => {
    const user = c.get("user");
    const job = await visibleJob(deps, user, c.req.param("id"));
    // The poster and admins see every attempt; a worker sees only their own (not a previous worker's).
    const all = await deps.store.listProofs(job.jobId);
    const seesAll = job.posterId === user.userId || isAdmin(deps, user);
    const proofs = seesAll ? all : all.filter((p) => p.workerId === user.userId);
    return c.json(
      proofs.map((p) => ({
        ...proofWire(deps, p),
        verdicts: verdictsWire(p),
        decision: p.grade?.decision ?? null,
        decidedBecause: p.grade?.decidedBecause ?? null,
        posterSummary: p.grade?.posterSummary ?? null,
        workerFeedback: p.grade?.workerFeedback ?? null,
      })),
    );
  });

  return app;
}
