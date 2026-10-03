// The HTTP API. One Hono app serves every route, locally (src/local.ts) and in Lambda (src/handlers/api.ts).

import { Hono } from "hono";
import { LocalBlobs } from "../blobs/index.js";
import type { Deps } from "../deps.js";
import { notFound } from "../lib/errors.js";
import { authRoutes, requireAuth } from "./auth.js";
import { toErrorResponse, type AppEnv } from "./http.js";
import { jobRoutes } from "./routes/jobs.js";
import { localBlobRoutes } from "./routes/localBlobs.js";
import { meRoutes } from "./routes/me.js";
import { offerRoutes } from "./routes/offers.js";
import { proofRoutes } from "./routes/proof.js";
import { twinRoutes } from "./routes/twin.js";
import { fileRoutes, uploadRoutes } from "./routes/uploads.js";

export function createApp(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.onError((err, c) => toErrorResponse(c, err, deps));
  app.notFound((c) => toErrorResponse(c, notFound("Route"), deps));

  app.get("/health", (c) => c.json({ ok: true, stage: deps.config.STAGE, demoMode: deps.config.DEMO_MODE }));
  app.route("/auth", authRoutes(deps));
  // Signed upload/download URLs for local dev (S3 handles these when deployed).
  if (deps.blobs instanceof LocalBlobs) app.route("/local-blobs", localBlobRoutes(deps.blobs));
  // Stable, signed links to uploaded files (redirect to a short-lived download URL).
  app.route("/files", fileRoutes(deps));

  // Everything below needs a session token.
  const authed = new Hono<AppEnv>();
  authed.use("*", requireAuth(deps));
  authed.route("/me", meRoutes(deps));
  authed.route("/twin", twinRoutes(deps));
  authed.route("/uploads", uploadRoutes(deps));
  authed.route("/jobs", jobRoutes(deps));
  authed.route("/jobs", proofRoutes(deps));
  authed.route("/offers", offerRoutes(deps));
  app.route("/", authed);

  return app;
}
