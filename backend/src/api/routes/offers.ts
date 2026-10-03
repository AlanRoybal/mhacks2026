import { Hono, type Context } from "hono";
import type { Deps } from "../../deps.js";
import { TransitionError } from "../../domain/jobMachine.js";
import type { Offer, User } from "../../domain/types.js";
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

  // US-26: what happened to an offer (accepted, declined, expired, or still live).
  app.get("/:id", async (c) => c.json({ offer: offerWire(await myOffer(deps, c.get("user"), c.req.param("id"))) }));

  const respond = (type: "ACCEPT" | "OFFER_DECLINED") => async (c: Context<AppEnv>) => {
    const user = c.get("user");
    const offer = await myOffer(deps, user, c.req.param("id") ?? "");
    try {
      await applyEvent(deps, offer.jobId, { type, offerId: offer.offerId }, c.get("actor"));
    } catch (e) {
      // A repeated tap after winning is a success, not "taken" (the notification and the app may both send it).
      if (!(type === "ACCEPT" && e instanceof TransitionError && e.code === "already_done")) throw e;
    }
    // The offer row is updated by an effect after the commit, so report the outcome directly.
    const answered: Offer = { ...offer, status: type === "ACCEPT" ? "accepted" : "declined" };
    const job = type === "ACCEPT" ? await jobWire(new WireContext(deps), await getJobOrThrow(deps, offer.jobId), user) : null;
    return c.json({ offer: offerWire(answered), job });
  };

  // US-24/29: accept (Face ID happens on the device). Exactly one worker can win; others get 409 offer_not_current.
  app.post("/:id/accept", respond("ACCEPT"));
  // US-25/30: decline; the job moves to the next match.
  app.post("/:id/decline", respond("OFFER_DECLINED"));

  return app;
}
