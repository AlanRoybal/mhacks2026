import { Hono, type Context } from "hono";
import type { Deps } from "../../deps.js";
import { TransitionError } from "../../domain/jobMachine.js";
import type { Job, Offer, User } from "../../domain/types.js";
import { notFound } from "../../lib/errors.js";
import { applyEvent, getJobOrThrow } from "../../services/jobs.js";
import type { AppEnv } from "../http.js";
import { jobWire, wireDate, WireContext } from "../wire.js";

export function offerWire(offer: Offer) {
  return {
    id: offer.offerId,
    jobId: offer.jobId,
    // queued | sent | accepted | declined | expired | canceled. The server's expiresAt is authoritative.
    status: offer.status,
    expiresAt: wireDate(offer.expiresAt),
    matchReason: offer.why,
    fit: offer.fit,
    estMinutes: offer.estMinutes,
    hourlyRate: offer.hourlyCents / 100,
    distanceMiles: offer.distanceKm === undefined ? null : Math.round((offer.distanceKm / 1.609344) * 10) / 10,
    travelMinutes: offer.travelMinutes ?? null,
  };
}

// Accept or decline. Exactly one worker can win; a repeated tap by the winner is a success.
// Returns the offer as answered (its row is updated by an effect after the commit) and the job.
export async function respondToOffer(deps: Deps, user: User, offerId: string, accept: boolean): Promise<{ offer: Offer; job: Job }> {
  const offer = await myOffer(deps, user, offerId);
  const type = accept ? "ACCEPT" : "OFFER_DECLINED";
  try {
    await applyEvent(deps, offer.jobId, { type, offerId: offer.offerId }, { kind: "user", userId: user.userId });
  } catch (e) {
    // The notification action and the app may both send the accept.
    if (!(accept && e instanceof TransitionError && e.code === "already_done")) throw e;
  }
  return { offer: { ...offer, status: accept ? "accepted" : "declined" }, job: await getJobOrThrow(deps, offer.jobId) };
}

async function myOffer(deps: Deps, user: User, offerId: string): Promise<Offer> {
  const offer = await deps.store.getOffer(offerId);
  if (!offer || offer.workerId !== user.userId) throw notFound("Offer");
  return offer;
}

export function offerRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  // The worker's live offer, if any (Home's "New match" card). 200 with { offer: null } when there is none.
  app.get("/current", async (c) => {
    const user = c.get("user");
    const now = deps.now().getTime();
    for (const offer of await deps.store.listOffersForWorker(user.userId)) {
      if (offer.status !== "sent" || !offer.expiresAt || Date.parse(offer.expiresAt) <= now) continue;
      const job = await deps.store.getJob(offer.jobId);
      if (job?.currentOffer?.offerId !== offer.offerId) continue;
      return c.json({ offer: offerWire(offer), job: await jobWire(new WireContext(deps), job, user) });
    }
    return c.json({ offer: null, job: null });
  });

  // US-26: what happened to an offer (accepted, declined, expired, or still live). Open this from the
  // push (it carries offerId): unlike /offers/current it never lags behind the notification.
  app.get("/:id", async (c) => {
    const user = c.get("user");
    const offer = await myOffer(deps, user, c.req.param("id"));
    const job = await deps.store.getJob(offer.jobId);
    const visible = job && (job.currentOffer?.offerId === offer.offerId || job.workerId === user.userId);
    return c.json({ offer: offerWire(offer), job: visible ? await jobWire(new WireContext(deps), job, user) : null });
  });

  const respond = (type: "ACCEPT" | "OFFER_DECLINED") => async (c: Context<AppEnv>) => {
    const user = c.get("user");
    const { offer, job } = await respondToOffer(deps, user, c.req.param("id") ?? "", type === "ACCEPT");
    return c.json({ offer: offerWire(offer), job: type === "ACCEPT" ? await jobWire(new WireContext(deps), job, user) : null });
  };

  // US-24/29: accept (Face ID happens on the device). Exactly one worker can win; others get 409 offer_not_current.
  app.post("/:id/accept", respond("ACCEPT"));
  // US-25/30: decline; the job moves to the next match.
  app.post("/:id/decline", respond("OFFER_DECLINED"));

  return app;
}
