import { Hono, type Context } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import type { JobEvent } from "../../domain/events.js";
import { captureKey } from "../../domain/ids.js";
import { MAX_BOUNTY_CENTS, MIN_BOUNTY_CENTS } from "../../domain/money.js";
import { Category, EvidenceType, type Actor, type Job, type User } from "../../domain/types.js";
import { badRequest, notFound } from "../../lib/errors.js";
import { applyEvent, getJobOrThrow } from "../../services/jobs.js";
import { createDraft, deleteDraft, regenerateChecklist, setChecklist, updateDetails, validateDeadline, type DraftInput } from "../../services/postings.js";
import { parseBody, parseOptionalBody, type AppEnv } from "../http.js";
import { jobWire, milesToKm, roleOf, timelineWire, WireContext } from "../wire.js";
import { ownedUploadKey } from "./uploads.js";

// Same shape as NewJobDraft in the iOS app, plus an optional matching radius.
const LocationIn = z.object({
  latitude: z.number().min(-90).max(90),
  longitude: z.number().min(-180).max(180),
  address: z.string().max(200).default(""),
});

const DraftFields = z.object({
  title: z.string().trim().min(3).max(80),
  description: z.string().trim().min(1).max(2000),
  category: Category,
  // null or missing means remote. Swift's JSONEncoder leaves out nil optionals entirely.
  location: LocationIn.nullish(),
  deadline: z.string().datetime({ offset: true }),
  payAmount: z.number().positive(),
  currency: z.enum(["USD", "USDC"]),
  posterPhotos: z.array(z.string()).max(6),
  radiusMiles: z.number().min(0.5).max(60).optional(),
});
const DraftBody = DraftFields.extend({ currency: DraftFields.shape.currency.default("USD"), posterPhotos: DraftFields.shape.posterPhotos.default([]) });
// No defaults here: a PATCH that leaves a field out must not reset it.
const DraftPatch = DraftFields.partial();

const ChecklistItemIn = z.object({
  id: z.string().min(1).max(40).optional(),
  text: z.string().trim().min(1).max(300),
  evidenceType: EvidenceType,
  photoCount: z.number().int().min(1).max(10).nullish(),
  required: z.boolean().optional(),
  beforeAfter: z.boolean().optional(),
  angleHint: z.string().max(200).nullish(),
});

const ChecklistBody = z.union([z.array(ChecklistItemIn), z.object({ checklist: z.array(ChecklistItemIn) })]);

export function centsOf(payAmount: number): number {
  const cents = Math.round(payAmount * 100);
  if (cents < MIN_BOUNTY_CENTS || cents > MAX_BOUNTY_CENTS) {
    throw badRequest(`Pay must be between $${MIN_BOUNTY_CENTS / 100} and $${MAX_BOUNTY_CENTS / 100}`, "invalid_amount");
  }
  return cents;
}

function draftInput(deps: Deps, user: User, body: Partial<z.infer<typeof DraftFields>>): Partial<DraftInput> {
  const input: Partial<DraftInput> = {};
  if (body.title !== undefined) input.title = body.title;
  if (body.description !== undefined) input.description = body.description;
  if (body.category !== undefined) input.category = body.category;
  if (body.location !== undefined) {
    input.location = body.location ? { lat: body.location.latitude, lng: body.location.longitude, address: body.location.address || undefined } : null;
  }
  if (body.deadline !== undefined) input.deadline = body.deadline;
  if (body.payAmount !== undefined) input.bountyCents = centsOf(body.payAmount);
  if (body.currency !== undefined) input.currency = body.currency;
  if (body.posterPhotos !== undefined) input.photos = body.posterPhotos.map((url) => ownedUploadKey(deps, user.userId, { fileURL: url }));
  if (body.radiusMiles !== undefined) input.radiusKm = milesToKm(body.radiusMiles);
  return input;
}

// Runs a state-machine event as the signed-in user and returns the updated job in wire format.
export async function act(deps: Deps, c: Context<AppEnv>, event: JobEvent, actor?: Actor) {
  const user = c.get("user");
  const job = await applyEvent(deps, c.req.param("id") ?? "", event, actor ?? c.get("actor"));
  return c.json(await jobWire(new WireContext(deps), job, user));
}

export async function visibleJob(deps: Deps, user: User, jobId: string): Promise<Job> {
  const job = await getJobOrThrow(deps, jobId);
  if (!roleOf(deps, job, user)) throw notFound("Job");
  return job;
}

export function jobRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const wire = (job: Job, user: User) => jobWire(new WireContext(deps), job, user);

  // US-11/13: create a draft; the response includes the AI-generated checklist.
  const create = async (c: Context<AppEnv>) => {
    const user = c.get("user");
    const body = await parseBody(c, DraftBody);
    const job = await createDraft(deps, user, draftInput(deps, user, { ...body, location: body.location ?? null }) as DraftInput);
    return c.json(await wire(job, user), 201);
  };
  app.post("/", create);
  app.post("/create", create);

  // Jobs I posted (newest first) and jobs I'm working on.
  app.get("/mine", async (c) => {
    const user = c.get("user");
    const ctx = new WireContext(deps);
    const jobs = await deps.store.listJobsByPoster(user.userId);
    return c.json(await Promise.all(jobs.map((j) => jobWire(ctx, j, user))));
  });

  app.get("/working", async (c) => {
    const user = c.get("user");
    const ctx = new WireContext(deps);
    const jobs = await deps.store.listJobsByWorker(user.userId);
    return c.json(await Promise.all(jobs.map((j) => jobWire(ctx, j, user))));
  });

  app.get("/:id", async (c) => {
    const user = c.get("user");
    return c.json(await wire(await getJobOrThrow(deps, c.req.param("id")), user));
  });

  app.patch("/:id", async (c) => {
    const user = c.get("user");
    const body = await parseBody(c, DraftPatch);
    return c.json(await wire(await updateDetails(deps, user, c.req.param("id"), draftInput(deps, user, body)), user));
  });

  app.delete("/:id", async (c) => {
    await deleteDraft(deps, c.get("user"), c.req.param("id"));
    return c.body(null, 204);
  });

  // US-14: save the poster's checklist edits. Accepts [items] or { checklist: [items] }.
  app.put("/:id/checklist", async (c) => {
    const user = c.get("user");
    const body = await parseBody(c, ChecklistBody);
    const items = (Array.isArray(body) ? body : body.checklist).map((i) => ({
      ...i,
      photoCount: i.photoCount ?? undefined,
      angleHint: i.angleHint ?? undefined,
    }));
    return c.json(await wire(await setChecklist(deps, user, c.req.param("id"), items), user));
  });

  app.post("/:id/checklist/regenerate", async (c) => {
    const user = c.get("user");
    return c.json(await wire(await regenerateChecklist(deps, user, c.req.param("id")), user));
  });

  // US-15: price, platform fee and total before checkout.
  app.get("/:id/quote", async (c) => {
    const job = await visibleJob(deps, c.get("user"), c.req.param("id"));
    return c.json({ payAmount: job.bountyCents / 100, feeAmount: job.feeCents / 100, totalAmount: job.totalCents / 100, currency: job.currency });
  });

  // US-17/49: every status change, oldest first.
  app.get("/:id/timeline", async (c) => {
    const user = c.get("user");
    const job = await visibleJob(deps, user, c.req.param("id"));
    return c.json(timelineWire(job, user, await deps.store.listLedger(job.jobId)));
  });

  // US-18: cancel before a worker accepts (full refund).
  app.post("/:id/cancel", (c) => act(deps, c, { type: "CANCEL" }));

  // Product rule 7: widen the radius or extend the deadline while no one has accepted.
  app.patch("/:id/terms", async (c) => {
    const body = await parseBody(c, z.object({ deadline: z.string().datetime({ offset: true }).optional(), radiusMiles: z.number().min(0.5).max(60).optional() }));
    const deadline = body.deadline === undefined ? undefined : validateDeadline(deps, body.deadline);
    return act(deps, c, { type: "UPDATE_TERMS", deadline, radiusKm: body.radiusMiles === undefined ? undefined : milesToKm(body.radiusMiles) });
  });

  // US-35/36: check in and start. The response carries captureKey, which the app signs its proof captures with.
  app.post("/:id/start", async (c) => {
    const body = await parseOptionalBody(
      c,
      z.object({ latitude: z.number().optional(), longitude: z.number().optional(), accuracyM: z.number().nonnegative().optional() }),
    );
    const at = body.latitude !== undefined && body.longitude !== undefined ? { lat: body.latitude, lng: body.longitude } : undefined;
    return act(deps, c, { type: "START", captureKey: captureKey(), at, accuracyM: body.accuracyM });
  });

  // Product rule 5: the worker can hand the job back before submitting; it re-opens for matching.
  // The worker is no longer on the job afterwards, so there is no job to return: 204.
  app.post("/:id/withdraw", async (c) => {
    await applyEvent(deps, c.req.param("id"), { type: "WITHDRAW" }, c.get("actor"));
    return c.body(null, 204);
  });

  return app;
}
