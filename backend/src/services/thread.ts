// The job thread: after a worker accepts, their twin texts the poster over iMessage (Photon), answers
// what it can from the job, saves details for the worker and relays questions it can't answer.
// Decisions (accept, approve, dispute, cancel) never happen here; the twin points to the app.
//
// Storage: one KV record per message (thread:<jobId>:<workerId>:<n>, written with ifAbsent so two
// writers can't overwrite each other) plus a count hint. A worker who withdraws ends their thread;
// the next worker starts a new one.

import type { ThreadInput } from "../ai/index.js";
import type { Deps } from "../deps.js";
import type { PushTemplate } from "../domain/events.js";
import type { Job, JobState, User } from "../domain/types.js";
import { newId } from "../domain/ids.js";
import { phoneKey } from "../messaging/messenger.js";
import { briefOf } from "./postings.js";
import { deliver } from "./notify.js";

export const THREAD_STATES: ReadonlySet<JobState> = new Set(["ACCEPTED", "IN_PROGRESS", "SUBMITTED", "IN_REVIEW", "DISPUTED"]);
const MAX_MESSAGES = 200;
const HISTORY_FOR_AI = 20;
const MAX_TEXT = 600;

export interface ThreadMessage {
  id: string;
  from: "twin" | "poster" | "worker";
  text: string;
  at: string;
  // Twin texts that passed a poster question on to the worker. Cleared by the worker's next reply.
  forWorker?: string;
  // Poster facts saved for the worker (gate code, parking, preferences).
  detail?: string;
}

const threadId = (job: Job, workerId = job.workerId) => `${job.jobId}:${workerId}`;
const msgKey = (id: string, n: number) => `thread:${id}:${n}`;
const countKey = (id: string) => `thread:${id}:count`;
// The poster's most recent thread, where an inbound text goes first.
const lastKey = (posterId: string) => `thread:last:${posterId}`;

export const firstName = (user: Pick<User, "displayName">) => user.displayName.trim().split(/\s+/)[0] || "Your worker";

export async function listMessages(deps: Deps, id: string): Promise<ThreadMessage[]> {
  const hint = (await deps.store.kvGet<number>(countKey(id))) ?? 0;
  const known = await Promise.all(Array.from({ length: hint }, (_, n) => deps.store.kvGet<ThreadMessage>(msgKey(id, n))));
  const messages = known.filter((m): m is ThreadMessage => m !== null);
  // The hint can lag a concurrent append; read on until the first gap.
  for (let n = hint; n < MAX_MESSAGES; n++) {
    const m = await deps.store.kvGet<ThreadMessage>(msgKey(id, n));
    if (!m) break;
    messages.push(m);
  }
  return messages;
}

async function append(deps: Deps, id: string, message: Omit<ThreadMessage, "id" | "at">): Promise<ThreadMessage> {
  const full: ThreadMessage = { id: newId(deps.now().getTime()), at: deps.now().toISOString(), ...message, text: message.text.slice(0, MAX_TEXT) };
  let n = (await deps.store.kvGet<number>(countKey(id))) ?? 0;
  while (n < MAX_MESSAGES && !(await deps.store.kvPut(msgKey(id, n), full, { ifAbsent: true }))) n++;
  if (n >= MAX_MESSAGES) throw new Error(`thread ${id} is full`);
  await deps.store.kvPut(countKey(id), n + 1);
  return full;
}

/** The poster can be texted: a verified number, job texts on, and a messenger configured. */
export function posterTextable(deps: Deps, poster: User): poster is User & { phone: NonNullable<User["phone"]> } {
  return deps.messenger.enabled && Boolean(poster.phone?.verifiedAt) && poster.phone?.jobTexts === true;
}

async function textPoster(deps: Deps, job: Job, poster: User & { phone: NonNullable<User["phone"]> }, message: Omit<ThreadMessage, "id" | "at" | "from">) {
  const id = threadId(job);
  const saved = await append(deps, id, { from: "twin", ...message });
  await deps.messenger.send(poster.phone.number, saved.text);
  await deps.store.kvPut(lastKey(poster.userId), id);
  return saved;
}

function statusLine(job: Job, worker: User): string {
  const name = firstName(worker);
  switch (job.state) {
    case "ACCEPTED": return `${name} accepted the job and hasn't checked in yet.`;
    case "IN_PROGRESS": return `${name} checked in and is working on it (started ${job.startedAt ?? "recently"}).`;
    case "SUBMITTED": return `${name} submitted proof; it's being reviewed automatically.`;
    case "IN_REVIEW": return "Proof is in the poster's Bounty app for review.";
    case "DISPUTED": return "The poster disputed the proof; Bounty is reviewing it.";
    default: return `The job is ${job.state.toLowerCase()}.`;
  }
}

async function turnInput(deps: Deps, job: Job, worker: User, history: ThreadMessage[], mode: ThreadInput["mode"], message?: string): Promise<ThreadInput> {
  return {
    mode,
    job: briefOf(job),
    checklist: job.checklist.map((c) => c.text),
    workerName: firstName(worker),
    status: `${statusLine(job, worker)} Deadline: ${job.deadline}.`,
    details: history.flatMap((m) => (m.detail ? [m.detail] : [])),
    history: history.slice(-HISTORY_FOR_AI).map((m) => ({ from: m.from, text: m.text })),
    message,
  };
}

/** The opening text, sent once per worker when they accept. */
export async function startThread(deps: Deps, job: Job): Promise<void> {
  if (!job.workerId || !THREAD_STATES.has(job.state)) return;
  const [poster, worker] = await Promise.all([deps.store.getUser(job.posterId), deps.store.getUser(job.workerId)]);
  if (!poster || !worker || !posterTextable(deps, poster)) return;
  const id = threadId(job);
  // Claim the thread so a retried effect never sends a second opener.
  if (!(await deps.store.kvPut(`thread:${id}:opened`, true, { ifAbsent: true }))) return;
  const turn = await deps.ai.threadTurn(await turnInput(deps, job, worker, [], "open"));
  await textPoster(deps, job, poster, { text: turn.reply });
  deps.log.info("Job thread opened", { jobId: job.jobId, workerId: job.workerId });
}

// What the twin texts the poster when the job moves. Templates not listed send nothing.
function updateText(template: PushTemplate, job: Job, name: string): string | null {
  const t = `"${job.title}"`;
  switch (template) {
    case "job_started": return `${name} just checked in and started ${t}.`;
    case "proof_ready": return `${name} finished ${t} and sent proof, which passed review. Approve it in the Bounty app, or it's paid automatically when the review window ends.`;
    case "proof_needs_decision": return `${name} sent proof for ${t}, but the automatic review couldn't confirm everything. Please check it in the Bounty app.`;
    case "worker_withdrew": return `${name} had to withdraw from ${t}. Bounty is finding someone else, so you don't need to do anything. Thanks for your patience.`;
    case "deadline_missed": return `The deadline for ${t} passed before ${name} finished, so you're being refunded. Sorry it didn't work out.`;
    default: return null;
  }
}

/** Called for every push to a job's poster: the accept opens the thread, later pushes become updates. */
export async function onPosterPush(deps: Deps, job: Job, poster: User, template: PushTemplate): Promise<void> {
  if (template === "offer_accepted") return startThread(deps, job);
  // A withdrawal has already cleared workerId; the update goes to the departing worker's thread.
  const workerId = job.workerId ?? (template === "worker_withdrew" ? await lastWorkerOf(deps, poster, job) : undefined);
  if (!workerId || !posterTextable(deps, poster)) return;
  if (!(await deps.store.kvGet(`thread:${threadId(job, workerId)}:opened`))) return;
  const worker = await deps.store.getUser(workerId);
  const text = worker && updateText(template, job, firstName(worker));
  if (!text) return;
  const saved = await append(deps, threadId(job, workerId), { from: "twin", text });
  await deps.messenger.send(poster.phone.number, saved.text);
}

async function lastWorkerOf(deps: Deps, poster: User, job: Job): Promise<string | undefined> {
  const last = await deps.store.kvGet<string>(lastKey(poster.userId));
  return last?.startsWith(`${job.jobId}:`) ? last.slice(job.jobId.length + 1) : undefined;
}

/** A text from a poster's phone (via the messenger service). */
export async function handleInboundText(deps: Deps, input: { from: string; text: string; messageId: string }): Promise<void> {
  if (!(await deps.store.kvPut(`imsg:${input.messageId}`, true, { ifAbsent: true, ttlSeconds: 7 * 24 * 3600 }))) return;
  const text = input.text.trim();
  if (!text) return;
  const userId = await deps.store.kvGet<string>(phoneKey(input.from));
  const poster = userId && userId !== "deleted" ? await deps.store.getUser(userId) : null;
  if (!poster || poster.phone?.number !== input.from) {
    await deps.messenger.send(input.from, "This number isn't linked to a Bounty account. Add it in the Bounty app under Account, then Text updates.");
    return;
  }
  const job = await activeThreadJob(deps, poster);
  if (!job?.workerId) {
    await deps.messenger.send(input.from, "You don't have a job in progress with a Bounty worker right now. Open the Bounty app to post or manage jobs.");
    return;
  }
  const worker = await deps.store.getUser(job.workerId);
  if (!worker) return;
  const id = threadId(job);
  const history = await listMessages(deps, id);
  const turn = await deps.ai.threadTurn(await turnInput(deps, job, worker, history, "reply", text));
  await append(deps, id, { from: "poster", text, detail: turn.detail.trim() || undefined });
  const forWorker = turn.forWorker.trim() || undefined;
  if (posterTextable(deps, poster)) await textPoster(deps, job, poster, { text: turn.reply, forWorker });
  if (forWorker || turn.detail.trim()) {
    await deliver(deps, worker, {
      type: "thread_message",
      jobId: job.jobId,
      title: forWorker ? `${firstName(poster)} asked a question` : `New detail from ${firstName(poster)}`,
      body: forWorker ?? turn.detail.trim(),
    });
  }
}

// The thread an inbound text belongs to: the poster's most recent one if it's still open, else any open one.
async function activeThreadJob(deps: Deps, poster: User): Promise<Job | null> {
  const last = await deps.store.kvGet<string>(lastKey(poster.userId));
  if (last) {
    const [jobId, workerId] = last.split(":");
    const job = jobId ? await deps.store.getJob(jobId) : null;
    if (job && job.posterId === poster.userId && job.workerId === workerId && THREAD_STATES.has(job.state)) return job;
  }
  const open = (await deps.store.listJobsByPoster(poster.userId)).filter((j) => j.workerId && THREAD_STATES.has(j.state));
  for (const job of open.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))) {
    if (await deps.store.kvGet(`thread:${threadId(job)}:opened`)) return job;
  }
  return null;
}

/** The worker answers (or adds something) from the app; the twin relays it to the poster. */
export async function workerMessage(deps: Deps, job: Job, worker: User, text: string): Promise<ThreadMessage> {
  const poster = await deps.store.getUser(job.posterId);
  if (!poster || !posterTextable(deps, poster)) throw new Error("poster_unreachable");
  const id = threadId(job);
  const saved = await append(deps, id, { from: "worker", text });
  await deps.messenger.send(poster.phone.number, `${firstName(worker)} says: ${saved.text}`);
  await deps.store.kvPut(lastKey(poster.userId), id);
  return saved;
}

export async function threadView(deps: Deps, job: Job, viewer: User) {
  const poster = viewer.userId === job.posterId ? viewer : await deps.store.getUser(job.posterId);
  const workerId = job.workerId;
  const messages = workerId ? await listMessages(deps, threadId(job, workerId)) : [];
  // The newest relayed question the worker hasn't answered since.
  const lastWorker = messages.findLastIndex((m) => m.from === "worker");
  const pending = messages.slice(lastWorker + 1).findLast((m) => m.forWorker)?.forWorker ?? null;
  return {
    // The twin can text this poster (they linked a phone and allow job texts).
    available: Boolean(poster && posterTextable(deps, poster)),
    active: THREAD_STATES.has(job.state) && Boolean(workerId),
    messages: messages.map((m) => ({ id: m.id, from: m.from, text: m.text, at: m.at.replace(/\.\d{3}Z$/, "Z"), detail: m.detail ?? null })),
    details: messages.flatMap((m) => (m.detail ? [m.detail] : [])),
    pendingQuestion: viewer.userId === workerId ? pending : null,
  };
}
