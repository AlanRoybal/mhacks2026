// Creating and editing job drafts. Once checkout starts, the price and checklist are locked
// (US-14, product rule 1: neither side can quietly change the agreement).

import { clamp, type ChecklistDraft, type JobBrief } from "../ai/index.js";
import { templateChecklist } from "../ai/fake.js";
import type { Deps } from "../deps.js";
import { newId } from "../domain/ids.js";
import { quote } from "../domain/money.js";
import type { Category, ChecklistItem, Currency, Job, Place, User } from "../domain/types.js";
import { badRequest, conflict, forbidden } from "../lib/errors.js";
import { VersionConflictError } from "../store/index.js";
import { createJobRecord, getJobOrThrow } from "./jobs.js";

export const MAX_CHECKLIST_ITEMS = 8;

export interface DraftInput {
  title: string;
  description: string;
  category: Category;
  location: Place | null;
  radiusKm?: number;
  deadline: string;
  bountyCents: number;
  currency: Currency;
  photos: string[];
  // Client-chosen ID (the payments checkout creates its own UUIDs). Defaults to a new ULID.
  jobId?: string;
}

// A checklist item as the app sends it. Fields it leaves out keep their previous value (matched by id).
export type ChecklistInput = Pick<ChecklistItem, "text" | "evidenceType"> & Partial<Omit<ChecklistItem, "text" | "evidenceType">>;

export const briefOf = (job: Pick<Job, "title" | "description" | "category" | "remote" | "bountyCents" | "estMinutes">): JobBrief => ({
  title: job.title,
  description: job.description,
  category: job.category,
  remote: job.remote,
  bountyCents: job.bountyCents,
  estMinutes: job.estMinutes || undefined,
});

function normalizeItem(input: ChecklistInput, id: string, previous?: ChecklistItem): ChecklistItem {
  const photo = input.evidenceType === "PHOTO";
  const angleHint = (input.angleHint ?? previous?.angleHint)?.trim();
  return {
    id,
    text: input.text.trim(),
    evidenceType: input.evidenceType,
    ...(photo ? { photoCount: Math.round(clamp(input.photoCount ?? previous?.photoCount ?? 1, 1, 10)) } : {}),
    ...(photo && (input.beforeAfter ?? previous?.beforeAfter) ? { beforeAfter: true } : {}),
    required: input.required ?? previous?.required ?? true,
    ...(photo && angleHint ? { angleHint } : {}),
  };
}

// Keeps ids the app sent (it makes UUIDs for new items) and numbers the rest c1, c2, ...
export function buildChecklist(items: ChecklistInput[], previous: ChecklistItem[] = []): ChecklistItem[] {
  const byId = new Map(previous.map((i) => [i.id, i]));
  const taken = new Set(items.map((i) => i.id).filter((id): id is string => Boolean(id)));
  let n = 1;
  const nextId = () => {
    while (taken.has(`c${n}`)) n++;
    taken.add(`c${n}`);
    return `c${n}`;
  };
  const seen = new Set<string>();
  return items.map((item) => {
    let id = item.id ?? nextId();
    if (seen.has(id)) id = nextId();
    seen.add(id);
    return normalizeItem(item, id, item.id ? byId.get(item.id) : undefined);
  });
}

// In-person proof always includes an on-site check-in.
function withCheckIn(checklist: ChecklistItem[], remote: boolean): ChecklistItem[] {
  if (remote) return checklist.filter((i) => i.evidenceType !== "CHECK_IN");
  if (checklist.some((i) => i.evidenceType === "CHECK_IN")) return checklist;
  return [...checklist, ...buildChecklist([...checklist, { text: "Checked in at the job location", evidenceType: "CHECK_IN" }]).slice(-1)];
}

// A job can only be graded fairly if some photo, link or file item must pass (a check-in alone proves
// nothing about the work). Used for AI drafts, poster edits, and before funding.
export function hasRequiredEvidence(checklist: ChecklistItem[]): boolean {
  return checklist.some((i) => i.required && i.evidenceType !== "CHECK_IN");
}

function fromDraft(draft: ChecklistDraft, job: JobBrief): { checklist: ChecklistItem[]; estMinutes: number; flags: string[] } {
  let source = draft.items.filter((i) => i.text.trim() && i.evidenceType !== "CHECK_IN");
  if (source.length === 0) source = templateChecklist(job).items.filter((i) => i.evidenceType !== "CHECK_IN");
  const items = source.slice(0, MAX_CHECKLIST_ITEMS).map((i) => ({ ...i, angleHint: i.angleHint || undefined }));
  const first = items[0];
  if (first && !items.some((i) => i.required)) first.required = true;
  return {
    checklist: withCheckIn(buildChecklist(items), job.remote),
    estMinutes: Math.round(clamp(draft.estMinutes, 5, 600)),
    flags: draft.flags.map((f) => f.trim()).filter(Boolean).slice(0, 5),
  };
}

// Deadlines are 30 minutes to 30 days away, when posting and when extending (UPDATE_TERMS).
export function validateDeadline(deps: Deps, deadline: string): string {
  const ms = Date.parse(deadline);
  const now = deps.now().getTime();
  if (!Number.isFinite(ms)) throw badRequest("Invalid deadline");
  if (ms < now + 30 * 60_000) throw badRequest("The deadline must be at least 30 minutes from now");
  if (ms > now + 30 * 24 * 3600_000) throw badRequest("The deadline must be within 30 days");
  return new Date(ms).toISOString();
}

function validatePhotos(user: User, photos: string[]): string[] {
  for (const key of photos) {
    if (!key.startsWith(`uploads/${user.userId}/`)) throw badRequest("Photos must be uploaded by you through /uploads/presign");
  }
  return photos.slice(0, 6);
}

function railFor(deps: Deps, currency: Currency): Job["rail"] {
  return currency === "USDC" ? "usdc" : deps.config.PAYMENTS_PROVIDER;
}

export async function createDraft(deps: Deps, poster: User, input: DraftInput): Promise<Job> {
  const deadline = validateDeadline(deps, input.deadline);
  const amounts = quote(input.bountyCents);
  const remote = input.location === null;
  const base = { title: input.title.trim(), description: input.description.trim(), category: input.category, remote, bountyCents: amounts.bountyCents, estMinutes: 0 };
  const generated = fromDraft(await deps.ai.generateChecklist(briefOf(base)), briefOf(base));
  const now = deps.now().toISOString();
  const job: Job = {
    jobId: input.jobId ?? newId(deps.now().getTime()),
    posterId: poster.userId,
    ...base,
    photos: validatePhotos(poster, input.photos),
    location: input.location ?? undefined,
    radiusKm: input.radiusKm ?? 8,
    deadline,
    estMinutes: generated.estMinutes,
    feeCents: amounts.feeCents,
    totalCents: amounts.totalCents,
    currency: input.currency,
    rail: railFor(deps, input.currency),
    state: "DRAFT",
    version: 1,
    checklist: generated.checklist,
    flags: generated.flags,
    excludedWorkerIds: [],
    failedAttempts: 0,
    payment: {},
    ratings: {},
    matchRounds: 0,
    createdAt: now,
    updatedAt: now,
  };
  await createJobRecord(deps, job, { kind: "user", userId: poster.userId });
  return job;
}

// Version-checked edit of a draft, so an edit never races with checkout.
export async function editDraft(deps: Deps, user: User, jobId: string, edit: (job: Job) => Job): Promise<Job> {
  const job = await getJobOrThrow(deps, jobId);
  if (job.posterId !== user.userId) throw forbidden("Only the poster can edit this job");
  if (job.state !== "DRAFT") throw conflict("locked", "The job is funded; its details and checklist are locked");
  if (job.payment.paymentIntentId) throw conflict("checkout_started", "Checkout already started at this price. Finish paying or delete the draft.");
  const next = { ...edit(structuredClone(job)), version: job.version + 1, updatedAt: deps.now().toISOString() };
  try {
    await deps.store.saveJob(job.version, next);
  } catch (e) {
    if (e instanceof VersionConflictError) throw conflict("busy", "The job changed; reload and try again");
    throw e;
  }
  return next;
}

export async function updateDetails(deps: Deps, user: User, jobId: string, patch: Partial<DraftInput>): Promise<Job> {
  const deadline = patch.deadline === undefined ? undefined : validateDeadline(deps, patch.deadline);
  const photos = patch.photos === undefined ? undefined : validatePhotos(user, patch.photos);
  const amounts = patch.bountyCents === undefined ? undefined : quote(patch.bountyCents);
  return editDraft(deps, user, jobId, (job) => {
    const next = { ...job };
    if (patch.title !== undefined) next.title = patch.title.trim();
    if (patch.description !== undefined) next.description = patch.description.trim();
    if (patch.category !== undefined) next.category = patch.category;
    if (patch.location !== undefined) {
      next.remote = patch.location === null;
      next.location = patch.location ?? undefined;
      next.checklist = withCheckIn(next.checklist, next.remote);
    }
    if (patch.radiusKm !== undefined) next.radiusKm = patch.radiusKm;
    if (deadline) next.deadline = deadline;
    if (photos) next.photos = photos;
    if (patch.currency !== undefined) {
      next.currency = patch.currency;
      next.rail = railFor(deps, patch.currency);
    }
    if (amounts) Object.assign(next, amounts);
    return next;
  });
}

export async function setChecklist(deps: Deps, user: User, jobId: string, items: ChecklistInput[]): Promise<Job> {
  if (items.length === 0 || items.length > MAX_CHECKLIST_ITEMS) throw badRequest(`A checklist needs 1 to ${MAX_CHECKLIST_ITEMS} items`);
  return editDraft(deps, user, jobId, (job) => {
    const checklist = withCheckIn(buildChecklist(items, job.checklist), job.remote);
    if (!hasRequiredEvidence(checklist)) throw badRequest("Mark at least one photo, link or file item as required");
    return { ...job, checklist };
  });
}

export async function regenerateChecklist(deps: Deps, user: User, jobId: string): Promise<Job> {
  const job = await getJobOrThrow(deps, jobId);
  if (job.posterId !== user.userId) throw forbidden("Only the poster can edit this job");
  const generated = fromDraft(await deps.ai.generateChecklist(briefOf(job)), briefOf(job));
  return editDraft(deps, user, jobId, (j) => ({ ...j, checklist: generated.checklist, estMinutes: generated.estMinutes, flags: generated.flags }));
}

export async function deleteDraft(deps: Deps, user: User, jobId: string): Promise<void> {
  const job = await getJobOrThrow(deps, jobId);
  if (job.posterId !== user.userId) throw forbidden("Only the poster can delete this job");
  if (job.state !== "DRAFT") throw conflict("locked", "Only drafts can be deleted. Cancel a funded job instead.");
  if (job.payment.paymentIntentId) throw conflict("checkout_started", "Checkout already started; wait for it to finish");
  await deps.store.deleteJob(jobId, job.version);
}
