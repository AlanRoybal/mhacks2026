import { Hono } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import type { User } from "../../domain/types.js";
import { conflict } from "../../lib/errors.js";
import { newUser, reliability, updateUser } from "../../services/users.js";
import { isAdmin } from "../auth.js";
import { parseBody, type AppEnv } from "../http.js";
import { wireDate } from "../wire.js";
import { workerTrust } from "../../services/risk.js";

const MAX_DEVICES = 5;
// Money is still held or moving for jobs in these states.
const OPEN_STATES = new Set(["FUNDED", "OFFERED", "ACCEPTED", "IN_PROGRESS", "SUBMITTED", "IN_REVIEW", "DISPUTED"]);

export function meView(deps: Deps, user: User) {
  const r = reliability(user.stats);
  const avg = (sum: number, count: number) => (count === 0 ? null : Math.round((sum / count) * 10) / 10);
  return {
    userId: user.userId,
    displayName: user.displayName,
    email: user.email ?? null,
    photoUrl: user.photoUrl ?? null,
    isAdmin: isAdmin(deps, user),
    payouts: { stripeConnected: Boolean(user.payouts.stripeAccountId), stripeTransfersEnabled: user.payouts.stripeTransfersEnabled },
    pushEnabled: user.devices.length > 0,
    stats: {
      ...user.stats,
      acceptRate: r.acceptRate,
      completionRate: r.completionRate,
      reliability: r.score,
      workerRating: avg(user.stats.ratingSum, user.stats.ratingCount),
      posterRating: avg(user.stats.posterRatingSum, user.stats.posterRatingCount),
    },
    createdAt: wireDate(user.createdAt),
  };
}

export function meRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.get("/", (c) => c.json(meView(deps, c.get("user"))));

  // The worker's trust score and the escrow it lets them hold at once (domain/risk.ts).
  app.get("/trust", async (c) => {
    const { trust, limitCents, openCents } = await workerTrust(deps, c.get("user"));
    return c.json({
      score: Math.round(trust.mean * 1000) / 1000,
      conservative: Math.round(trust.lower * 1000) / 1000,
      effectiveJobs: Math.round(trust.effectiveJobs * 10) / 10,
      exposureLimit: limitCents / 100,
      openExposure: openCents / 100,
    });
  });

  app.patch("/", async (c) => {
    const body = await parseBody(c, z.object({ displayName: z.string().trim().min(1).max(60) }));
    const user = await updateUser(deps, c.get("user").userId, (u) => {
      u.displayName = body.displayName;
    });
    return c.json(meView(deps, user));
  });

  // Account deletion (settings): wipes personal data and the twin, and unlinks the sign-in identities so
  // the next sign-in starts a new account. Jobs and ledger rows stay, since the other party and payment
  // records depend on them. Refused while any job is open, because money is still held for it.
  app.delete("/", async (c) => {
    const user = c.get("user");
    const [posted, working] = await Promise.all([deps.store.listJobsByPoster(user.userId), deps.store.listJobsByWorker(user.userId)]);
    if ([...posted, ...working].some((j) => OPEN_STATES.has(j.state))) {
      throw conflict("open_jobs", "Finish or cancel your open jobs before deleting your account");
    }
    for (const [provider, subject] of Object.entries(user.identities)) {
      // There is no KV delete; an entry that expires in a second reads as absent, so the identity is free again.
      if (subject) await deps.store.kvPut(`identity:${provider}:${subject}`, "deleted", { ttlSeconds: 1 });
    }
    await updateUser(deps, user.userId, (u) => {
      const blank = newUser({ userId: u.userId, displayName: "Deleted user" }, deps.now());
      u.displayName = blank.displayName;
      u.email = undefined;
      u.photoUrl = undefined;
      u.identities = {};
      u.twin = blank.twin;
      u.prefs = blank.prefs;
      u.availability = undefined;
      u.devices = [];
      u.inbox = undefined;
      u.inboxReadAt = undefined;
    });
    deps.log.info("Account deleted", { userId: user.userId });
    return c.body(null, 204);
  });

  // Called after registerForRemoteNotifications. env is "sandbox" for Xcode builds, "production" for TestFlight.
  app.post("/devices", async (c) => {
    const body = await parseBody(c, z.object({ token: z.string().regex(/^[0-9a-f]{64,200}$/i), env: z.enum(["sandbox", "production"]) }));
    const now = deps.now().toISOString();
    const user = await updateUser(deps, c.get("user").userId, (u) => {
      const others = u.devices.filter((d) => d.token !== body.token);
      u.devices = [{ token: body.token.toLowerCase(), env: body.env, updatedAt: now }, ...others].slice(0, MAX_DEVICES);
    });
    return c.json({ devices: user.devices.length });
  });

  // The notifications page, newest first. Opening it calls POST /me/notifications/read.
  app.get("/notifications", (c) => {
    const user = c.get("user");
    const readAt = user.inboxReadAt ?? "";
    const items = (user.inbox ?? []).map((n) => ({
      id: n.id,
      type: n.type,
      title: n.title,
      body: n.body,
      jobId: n.jobId,
      offerId: n.offerId ?? null,
      createdAt: wireDate(n.createdAt),
      read: n.createdAt <= readAt,
    }));
    return c.json({ items, unreadCount: items.filter((n) => !n.read).length });
  });

  app.post("/notifications/read", async (c) => {
    await updateUser(deps, c.get("user").userId, (u) => {
      u.inboxReadAt = deps.now().toISOString();
    });
    return c.json({ unreadCount: 0 });
  });

  return app;
}
