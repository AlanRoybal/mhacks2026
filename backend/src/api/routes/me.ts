import { Hono } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import type { User } from "../../domain/types.js";
import { reliability, updateUser } from "../../services/users.js";
import { isAdmin } from "../auth.js";
import { parseBody, type AppEnv } from "../http.js";
import { wireDate } from "../wire.js";

const MAX_DEVICES = 5;

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

  app.patch("/", async (c) => {
    const body = await parseBody(c, z.object({ displayName: z.string().trim().min(1).max(60) }));
    const user = await updateUser(deps, c.get("user").userId, (u) => {
      u.displayName = body.displayName;
    });
    return c.json(meView(deps, user));
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

  return app;
}
