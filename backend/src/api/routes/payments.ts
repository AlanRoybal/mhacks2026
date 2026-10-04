import { Hono } from "hono";
import { jwtVerify, SignJWT } from "jose";
import type { Deps } from "../../deps.js";
import { z } from "zod";
import { badRequest } from "../../lib/errors.js";
import { createIncomeStatement, getIncomeStatement, verificationPage, verifyUrl } from "../../services/income.js";
import { updateUser } from "../../services/users.js";
import { connectOnboardingUrl, earnings, handleStripeWebhook, startFunding, syncPayoutStatus } from "../../services/payments.js";
import { parseBody, type AppEnv } from "../http.js";
import { jobWire, WireContext } from "../wire.js";

const secret = (deps: Deps) => new TextEncoder().encode(deps.config.JWT_SECRET);

async function refreshUrlFor(deps: Deps, userId: string): Promise<string> {
  const token = await new SignJWT({ typ: "connect_refresh" }).setProtectedHeader({ alg: "HS256" }).setSubject(userId).setExpirationTime("1d").sign(secret(deps));
  return `${deps.config.PUBLIC_BASE_URL}/wallet/connect/refresh?t=${token}`;
}

// Authenticated payment routes, mounted under /jobs and /wallet.
export function fundingRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  // US-15/16: returns a FundingSession for Stripe PaymentSheet (Apple Pay or card). Funding is confirmed
  // by Stripe's webhook, after which the job moves to FUNDED. provider "fake" means already funded.
  app.post("/:id/fund", async (c) => {
    const user = c.get("user");
    const { session, job } = await startFunding(deps, user, c.req.param("id"));
    return c.json({ ...session, job: await jobWire(new WireContext(deps), job, user) });
  });

  return app;
}

export function walletRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.get("/earnings", async (c) => c.json(await earnings(deps, c.get("user"))));

  // Tax set-aside: the share of each payout the Earnings tab tracks for taxes (0-50%). Nothing is withheld.
  app.put("/tax", async (c) => {
    const { percent } = await parseBody(c, z.object({ percent: z.number().int().min(0).max(50) }));
    const user = await updateUser(deps, c.get("user").userId, (u) => {
      u.taxSetAsidePercent = percent;
    });
    return c.json(await earnings(deps, user));
  });

  // A verified income statement from the escrow ledger, with a public link anyone can check.
  app.post("/income-statement", async (c) => {
    const { period } = await parseBody(c, z.object({ period: z.enum(["year", "90d", "all"]).default("year") }));
    const statement = await createIncomeStatement(deps, c.get("user"), period);
    return c.json({ ...statement, verifyUrl: verifyUrl(deps, statement.id) });
  });

  // US-52: open the returned url in SFSafariViewController. Stripe sends the worker back to
  // <scheme>://wallet?status=returned; then call POST /wallet/connect/sync to refresh the status.
  app.post("/connect", async (c) => {
    const user = c.get("user");
    return c.json({ url: await connectOnboardingUrl(deps, user, await refreshUrlFor(deps, user.userId)) });
  });

  app.post("/connect/sync", async (c) => {
    const user = await syncPayoutStatus(deps, c.get("user"));
    return c.json({ stripeConnected: Boolean(user.payouts.stripeAccountId), payoutsEnabled: user.payouts.stripeTransfersEnabled });
  });

  return app;
}

// Public routes: Stripe webhooks and Connect redirects (no session token available there).
export function publicPaymentRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.post("/webhooks/stripe", async (c) => {
    const signature = c.req.header("stripe-signature");
    if (!signature) throw badRequest("Missing Stripe-Signature header");
    await handleStripeWebhook(deps, await c.req.text(), signature);
    return c.json({ received: true });
  });

  // The page behind an income statement's verification link (no sign-in: the unguessable ID is the key).
  app.get("/verify/income/:id", async (c) => {
    const statement = await getIncomeStatement(deps, c.req.param("id"));
    return c.html(verificationPage(statement), statement ? 200 : 404);
  });

  app.get("/wallet/connect/return", (c) => c.redirect(`${deps.config.APP_URL_SCHEME}://wallet?status=returned`));

  // Stripe calls this when an onboarding link expired; mint a fresh one.
  app.get("/wallet/connect/refresh", async (c) => {
    try {
      const { payload } = await jwtVerify(c.req.query("t") ?? "", secret(deps), { algorithms: ["HS256"] });
      const user = payload.typ === "connect_refresh" && payload.sub ? await deps.store.getUser(payload.sub) : null;
      if (!user) throw new Error("unknown user");
      return c.redirect(await connectOnboardingUrl(deps, user, await refreshUrlFor(deps, user.userId)));
    } catch {
      return c.redirect(`${deps.config.APP_URL_SCHEME}://wallet?status=expired`);
    }
  });

  return app;
}
