import { Hono } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import { forbidden } from "../../lib/errors.js";
import { isAdmin } from "../auth.js";
import { parseBody, type AppEnv } from "../http.js";
import { act } from "./jobs.js";

// Poster review, disputes and ratings. Each returns the updated Job.
export function reviewRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  // US-46: approve and release payment. Also how a poster drops a dispute they opened.
  app.post("/:id/approve", (c) => act(deps, c, { type: "APPROVE" }));

  // Refund work that failed AI review after the worker's retries.
  app.post("/:id/reject", (c) => act(deps, c, { type: "REJECT" }));

  // US-50: dispute one checklist item during the review window. Body matches the app:
  // { checklistItemId, note } (also accepts { itemId, reason }).
  app.post("/:id/dispute", async (c) => {
    const body = await parseBody(
      c,
      z.object({ checklistItemId: z.string().optional(), itemId: z.string().optional(), note: z.string().max(1000).optional(), reason: z.string().max(1000).optional() }),
    );
    return act(deps, c, { type: "DISPUTE", itemId: body.checklistItemId ?? body.itemId ?? "", reason: body.note ?? body.reason ?? "" });
  });

  // US-51: an admin (never a party to the job) releases or refunds a disputed job.
  app.post("/:id/resolve", async (c) => {
    const user = c.get("user");
    if (!isAdmin(deps, user)) throw forbidden("Only an admin can resolve disputes");
    const body = await parseBody(c, z.object({ outcome: z.enum(["release", "refund"]), note: z.string().max(1000).optional() }));
    return act(deps, c, { type: "RESOLVE", outcome: body.outcome, note: body.note }, { kind: "admin", userId: user.userId });
  });

  // US-56/57: rate the other side once the job is closed.
  app.post("/:id/rating", async (c) => {
    const body = await parseBody(c, z.object({ stars: z.number().int().min(1).max(5), comment: z.string().max(500).optional() }));
    return act(deps, c, { type: "RATE", stars: body.stars, comment: body.comment });
  });

  return app;
}
