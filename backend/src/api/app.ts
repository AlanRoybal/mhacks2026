// The HTTP API. One Hono app serves every route, locally (src/local.ts) and in Lambda (src/handlers/api.ts).

import { Hono } from "hono";
import { LocalBlobs } from "../blobs/index.js";
import type { Deps } from "../deps.js";
import { notFound } from "../lib/errors.js";
import { authRoutes, requireAuth } from "./auth.js";
import { adminRoutes } from "./routes/admin.js";
import { demoRoutes } from "./routes/demo.js";
import { toErrorResponse, type AppEnv } from "./http.js";
import { jobRoutes } from "./routes/jobs.js";
import { localBlobRoutes } from "./routes/localBlobs.js";
import { meRoutes } from "./routes/me.js";
import { offerRoutes } from "./routes/offers.js";
import { fundingRoutes, publicPaymentRoutes, walletRoutes } from "./routes/payments.js";
import { proofRoutes } from "./routes/proof.js";
import { reviewRoutes } from "./routes/review.js";
import { twinRoutes } from "./routes/twin.js";
import { twinKitRoutes } from "./routes/twinkit.js";
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
  // Stripe webhooks and Connect redirects.
  app.route("/", publicPaymentRoutes(deps));

  // Everything below needs a session token.
  const authed = new Hono<AppEnv>();
  authed.use("*", requireAuth(deps));
  authed.route("/me", meRoutes(deps));
  authed.route("/twin", twinRoutes(deps));
  authed.route("/uploads", uploadRoutes(deps));
  authed.route("/jobs", jobRoutes(deps));
  authed.route("/jobs", proofRoutes(deps));
  authed.route("/jobs", reviewRoutes(deps));
  authed.route("/offers", offerRoutes(deps));
  authed.route("/jobs", fundingRoutes(deps));
  authed.route("/wallet", walletRoutes(deps));
  authed.route("/admin", adminRoutes(deps));
  // The same features in the shape TwinKit (iosA's networking package) expects.
  authed.route("/", twinKitRoutes(deps));
  if (deps.config.DEMO_MODE || deps.config.STAGE === "local") authed.route("/demo", demoRoutes(deps));
  app.route("/", authed);

  return app;
}
