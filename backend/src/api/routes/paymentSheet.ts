// The two endpoints the payments checkout calls (Bounty/Features/Post/PaymentCheckoutView.swift, from
// the payments branch): POST /payment-sheet and GET /jobs/<uuid>. They used to live on a separate
// sandbox server (payments-server/); here the funded job becomes a real job that gets matched.
// Responses and errors keep that server's shapes: FundedJob, and { error: "<message>" }.

import { Hono, type Context } from "hono";
import { jwtVerify } from "jose";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import { MAX_BOUNTY_CENTS, MIN_BOUNTY_CENTS } from "../../domain/money.js";
import type { Category, Job, User } from "../../domain/types.js";
import { AppError } from "../../lib/errors.js";
import { getJobOrThrow } from "../../services/jobs.js";
import { startFunding, syncFundingFromStripe } from "../../services/payments.js";
import { createDraft } from "../../services/postings.js";
import { newUser } from "../../services/users.js";
import type { AppEnv } from "../http.js";

const UUID = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}";

const CATEGORY: Record<string, Category> = { Design: "DESIGN", Home: "HOME", Tutoring: "TUTORING", Photography: "PHOTOGRAPHY", Technology: "TECHNOLOGY" };
const CATEGORY_NAME: Partial<Record<Category, string>> = { DESIGN: "Design", HOME: "Home", TUTORING: "Tutoring", PHOTOGRAPHY: "Photography", TECHNOLOGY: "Technology" };

// Same shape as FundingDraft in the app, plus an optional location the app may add later.
const FundingDraft = z.object({
  id: z.string().regex(new RegExp(`^${UUID}$`)),
  title: z.string().trim().min(1).max(120),
  details: z.string().trim().min(1).max(4000),
  category: z.enum(["Design", "Home", "Tutoring", "Photography", "Technology"]),
  isRemote: z.boolean(),
  deadline: z.string().datetime({ offset: true }),
  amountCents: z.number().int(),
  location: z.object({ latitude: z.number(), longitude: z.number(), address: z.string().default("") }).optional(),
});

// In-person jobs need a place to match against. The checkout doesn't send one yet, so they are placed at
// the campus default until the app adds `location` to FundingDraft.
const DEFAULT_PLACE = { lat: 42.2768, lng: -83.7382, address: "Ann Arbor, MI (location to be confirmed)" };

function fundedJob(job: Job) {
  return {
    id: job.jobId,
    title: job.title,
    details: job.description,
    category: CATEGORY_NAME[job.category] ?? "Home",
    isRemote: job.remote,
    // The app parses this with fractional seconds.
    deadline: new Date(job.deadline).toISOString(),
    amountCents: job.bountyCents,
    feeCents: job.feeCents,
    totalCents: job.totalCents,
    currency: "usd",
    status: job.state === "DRAFT" ? "draft" : job.state === "REFUNDED" ? "refunded" : "funded",
  };
}

const fail = (c: Context<AppEnv>, status: 400 | 401 | 403 | 404 | 409 | 501 | 502, message: string) => c.json({ error: message }, status);

export function paymentSheetRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  // The checkout sends no session yet. With one, the job belongs to that user; without one (local dev
  // only), to a shared guest poster.
  async function poster(c: Context<AppEnv>): Promise<User | null> {
    const header = c.req.header("authorization") ?? "";
    if (header.startsWith("Bearer ")) {
      try {
        const { payload } = await jwtVerify(header.slice(7), new TextEncoder().encode(deps.config.JWT_SECRET), { algorithms: ["HS256"] });
        return payload.sub ? await deps.store.getUser(payload.sub) : null;
      } catch {
        return null;
      }
    }
    if (deps.config.STAGE !== "local") return null;
    const key = "identity:demo:guest-poster";
    const existing = await deps.store.kvGet<string>(key);
    if (existing) return deps.store.getUser(existing);
    const guest = newUser({ displayName: "Guest poster", identities: { demo: "guest-poster" } }, deps.now());
    await deps.store.createUser(guest);
    await deps.store.kvPut(key, guest.userId, { ifAbsent: true });
    return guest;
  }

  app.post("/payment-sheet", async (c) => {
    try {
      const user = await poster(c);
      if (!user) return fail(c, 401, "Sign in to post a job.");
      const parsed = FundingDraft.safeParse(await c.req.json().catch(() => null));
      if (!parsed.success) return fail(c, 400, "Check the job details and try again.");
      const draft = parsed.data;
      if (draft.amountCents < MIN_BOUNTY_CENTS || draft.amountCents > MAX_BOUNTY_CENTS) {
        return fail(c, 400, `Pay must be between $${MIN_BOUNTY_CENTS / 100} and $${MAX_BOUNTY_CENTS / 100}`);
      }
      const jobId = draft.id.toLowerCase();

      let job = await deps.store.getJob(jobId);
      if (job && job.posterId !== user.userId) return fail(c, 409, "This checkout already belongs to another job. Start a new checkout.");
      if (!job) {
        job = await createDraft(deps, user, {
          jobId,
          title: draft.title,
          description: draft.details,
          category: CATEGORY[draft.category] ?? "OTHER",
          location: draft.isRemote ? null : draft.location ? { lat: draft.location.latitude, lng: draft.location.longitude, address: draft.location.address || undefined } : DEFAULT_PLACE,
          deadline: draft.deadline,
          bountyCents: draft.amountCents,
          currency: "USD",
          photos: [],
        });
      }
      if (job.state !== "DRAFT") {
        // Already paid: the app records it and skips the sheet.
        return c.json({ job: fundedJob(job), paymentIntentClientSecret: "", publishableKey: deps.config.STRIPE_PUBLISHABLE_KEY ?? "pk_test_fake" });
      }
      const { session, job: funded } = await startFunding(deps, user, jobId);
      // The fake rail funds immediately; the app only accepts test-mode keys, so present it as one.
      const publishableKey = session.provider === "fake" ? "pk_test_fake" : session.publishableKey;
      return c.json({ job: fundedJob(funded), paymentIntentClientSecret: session.paymentIntentClientSecret, publishableKey });
    } catch (e) {
      if (e instanceof AppError) return fail(c, e.status === 422 ? 400 : (e.status as 400 | 401 | 403 | 404 | 409 | 501 | 502), e.message);
      deps.log.error("Checkout failed", { error: e });
      return fail(c, 502, "Unable to reach the payment service. Please retry.");
    }
  });

  // Status poll after the sheet closes. Public like the old server (the UUID is the capability), but a
  // request with a session token goes to the normal GET /jobs/:id instead.
  app.get(`/jobs/:id{${UUID}}`, async (c, next) => {
    if (c.req.header("authorization")) return next();
    try {
      const job = await syncFundingFromStripe(deps, await getJobOrThrow(deps, c.req.param("id").toLowerCase()));
      return c.json(fundedJob(job));
    } catch (e) {
      if (e instanceof AppError && e.status === 404) return fail(c, 404, "Job not found.");
      deps.log.error("Checkout status failed", { error: e });
      return fail(c, 502, "Unable to reach the payment service. Please retry.");
    }
  });

  return app;
}
