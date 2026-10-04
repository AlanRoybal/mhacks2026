import type { Deps } from "../deps.js";
import type { Effect } from "../domain/events.js";
import { newId } from "../domain/ids.js";
import type { InboxItem } from "../domain/types.js";
import { renderPush } from "../push/templates.js";
import { updateUser } from "./users.js";

export const INBOX_LIMIT = 50;

// Best-effort: a failed push is logged, never retried, and never blocks the job.
export async function sendJobPush(deps: Deps, jobId: string, effect: Extract<Effect, { kind: "push" }>): Promise<void> {
  const [job, user, offer] = await Promise.all([
    deps.store.getJob(jobId),
    deps.store.getUser(effect.to),
    effect.offerId ? deps.store.getOffer(effect.offerId) : Promise.resolve(null),
  ]);
  if (!job || !user) return;
  // An offer push that runs late (retries, a slow stream) must not advertise an offer that moved on.
  if (effect.template === "offer" && job.currentOffer?.offerId !== effect.offerId) return;
  const message = renderPush(effect.template, job, offer);
  // Kept even when the user has no device, so the notifications page shows everything we tried to send.
  const item: InboxItem = {
    id: newId(deps.now().getTime()),
    type: message.type,
    title: message.title,
    body: message.body,
    jobId: message.jobId,
    offerId: message.offerId,
    createdAt: deps.now().toISOString(),
  };
  await updateUser(deps, user.userId, (u) => {
    u.inbox = [item, ...(u.inbox ?? [])].slice(0, INBOX_LIMIT);
  }).catch((error) => deps.log.warn("Inbox write failed", { userId: user.userId, error }));
  const { deadTokens } = await deps.push.send(user, message);
  if (deadTokens.length > 0) {
    await updateUser(deps, user.userId, (u) => {
      u.devices = u.devices.filter((d) => !deadTokens.includes(d.token));
    });
  }
}
