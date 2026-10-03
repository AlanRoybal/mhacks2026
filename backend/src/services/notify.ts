import type { Deps } from "../deps.js";
import type { Effect } from "../domain/events.js";
import { renderPush } from "../push/templates.js";
import { updateUser } from "./users.js";

// Best-effort: a failed push is logged, never retried, and never blocks the job.
export async function sendJobPush(deps: Deps, jobId: string, effect: Extract<Effect, { kind: "push" }>): Promise<void> {
  const [job, user, offer] = await Promise.all([
    deps.store.getJob(jobId),
    deps.store.getUser(effect.to),
    effect.offerId ? deps.store.getOffer(effect.offerId) : Promise.resolve(null),
  ]);
  if (!job || !user) return;
  const { deadTokens } = await deps.push.send(user, renderPush(effect.template, job, offer));
  if (deadTokens.length > 0) {
    await updateUser(deps, user.userId, (u) => {
      u.devices = u.devices.filter((d) => !deadTokens.includes(d.token));
    });
  }
}
