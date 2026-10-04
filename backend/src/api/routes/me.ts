import { createHash, randomInt, timingSafeEqual } from "node:crypto";
import { Hono } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import type { User } from "../../domain/types.js";
import { AppError, badRequest, conflict } from "../../lib/errors.js";
import { normalizePhone, phoneKey } from "../../messaging/messenger.js";
import { newUser, reliability, updateUser } from "../../services/users.js";
import { isAdmin } from "../auth.js";
import { parseBody, type AppEnv } from "../http.js";
import { wireDate } from "../wire.js";
import { workerTrust } from "../../services/risk.js";

const MAX_DEVICES = 5;
const CODE_TTL_MS = 10 * 60_000;
const CODE_RESEND_MS = 30_000;
const MAX_CODE_ATTEMPTS = 5;

const codeHash = (userId: string, code: string) => createHash("sha256").update(`${userId}:${code}`).digest("hex");
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
    // Texts about your jobs (Photon iMessage). textsAvailable is false when this server can't send texts.
    phone: user.phone ? { number: user.phone.number, jobTexts: user.phone.jobTexts } : null,
    textsAvailable: deps.messenger.enabled,
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
    if (user.phone && (await deps.store.kvGet<string>(phoneKey(user.phone.number))) === user.userId) {
      await deps.store.kvPut(phoneKey(user.phone.number), "deleted", { ttlSeconds: 1 });
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
      u.phone = undefined;
      u.phoneVerification = undefined;
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

  // Phone linking: POST /me/phone texts a 6-digit code, POST /me/phone/verify checks it.
  app.post("/phone", async (c) => {
    if (!deps.messenger.enabled) throw new AppError(501, "texts_not_configured", "Text messages aren't set up on this server.");
    const body = await parseBody(c, z.object({ number: z.string().min(7).max(24) }));
    const number = normalizePhone(body.number);
    if (!number) throw badRequest("Enter a mobile number, like (734) 555-0100 or +44 7700 900123.", "invalid_phone");
    const user = c.get("user");
    const pending = user.phoneVerification;
    if (pending && pending.number === number && deps.now().getTime() - Date.parse(pending.sentAt) < CODE_RESEND_MS) {
      throw conflict("code_recently_sent", "We just sent a code. Wait a few seconds before asking for another.");
    }
    const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
    try {
      await deps.messenger.send(number, `Your Bounty code is ${code}. It expires in 10 minutes. If you didn't ask for it, ignore this text.`);
    } catch (error) {
      deps.log.warn("Verification text failed", { userId: user.userId, error });
      throw new AppError(502, "text_failed", "We couldn't text that number. Check it and try again.");
    }
    const now = deps.now();
    await updateUser(deps, user.userId, (u) => {
      u.phoneVerification = { number, codeHash: codeHash(u.userId, code), expiresAt: new Date(now.getTime() + CODE_TTL_MS).toISOString(), attempts: 0, sentAt: now.toISOString() };
    });
    return c.json({ number, expiresAt: wireDate(new Date(now.getTime() + CODE_TTL_MS).toISOString()) });
  });

  app.post("/phone/verify", async (c) => {
    const body = await parseBody(c, z.object({ code: z.string().regex(/^\d{6}$/, "Enter the 6-digit code") }));
    const user = c.get("user");
    const pending = user.phoneVerification;
    if (!pending || Date.parse(pending.expiresAt) <= deps.now().getTime()) throw badRequest("That code expired. Ask for a new one.", "code_expired");
    if (pending.attempts >= MAX_CODE_ATTEMPTS) throw badRequest("Too many wrong codes. Ask for a new one.", "code_locked");
    const ok = timingSafeEqual(Buffer.from(codeHash(user.userId, body.code)), Buffer.from(pending.codeHash));
    if (!ok) {
      await updateUser(deps, user.userId, (u) => {
        if (u.phoneVerification) u.phoneVerification.attempts += 1;
      });
      throw badRequest("That code doesn't match. Check the text and try again.", "code_mismatch");
    }
    const previous = user.phone?.number;
    const next = await updateUser(deps, user.userId, (u) => {
      u.phone = { number: pending.number, verifiedAt: deps.now().toISOString(), jobTexts: u.phone?.jobTexts ?? true };
      u.phoneVerification = undefined;
    });
    // The latest account to verify a number receives its texts.
    await deps.store.kvPut(phoneKey(pending.number), user.userId);
    if (previous && previous !== pending.number && (await deps.store.kvGet<string>(phoneKey(previous))) === user.userId) {
      await deps.store.kvPut(phoneKey(previous), "deleted", { ttlSeconds: 1 });
    }
    return c.json(meView(deps, next));
  });

  app.patch("/phone", async (c) => {
    const body = await parseBody(c, z.object({ jobTexts: z.boolean() }));
    const user = await updateUser(deps, c.get("user").userId, (u) => {
      if (u.phone) u.phone.jobTexts = body.jobTexts;
    });
    return c.json(meView(deps, user));
  });

  app.delete("/phone", async (c) => {
    const user = c.get("user");
    if (user.phone && (await deps.store.kvGet<string>(phoneKey(user.phone.number))) === user.userId) {
      await deps.store.kvPut(phoneKey(user.phone.number), "deleted", { ttlSeconds: 1 });
    }
    const next = await updateUser(deps, user.userId, (u) => {
      u.phone = undefined;
      u.phoneVerification = undefined;
    });
    return c.json(meView(deps, next));
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
