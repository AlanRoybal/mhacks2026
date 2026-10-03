// The HTTP API. One Hono app serves every route, locally (src/local.ts) and in Lambda (src/handlers/api.ts).

import { Hono } from "hono";
import type { Deps } from "../deps.js";
import { notFound } from "../lib/errors.js";
import { authRoutes, requireAuth } from "./auth.js";
import { toErrorResponse, type AppEnv } from "./http.js";
import { meRoutes } from "./routes/me.js";

export function createApp(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.onError((err, c) => toErrorResponse(c, err, deps));
  app.notFound((c) => toErrorResponse(c, notFound("Route"), deps));

  app.get("/health", (c) => c.json({ ok: true, stage: deps.config.STAGE, demoMode: deps.config.DEMO_MODE }));
  app.route("/auth", authRoutes(deps));

  // Everything below needs a session token.
  const authed = new Hono<AppEnv>();
  authed.use("*", requireAuth(deps));
  authed.route("/me", meRoutes(deps));
  app.route("/", authed);

  return app;
}
