import { Hono } from "hono";
import type { Deps } from "../../deps.js";
import { forbidden } from "../../lib/errors.js";
import { isAdmin } from "../auth.js";
import type { AppEnv } from "../http.js";
import { jobWire, WireContext } from "../wire.js";

// US-51: what an admin needs to decide disputes.
export function adminRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.use("*", async (c, next) => {
    if (!isAdmin(deps, c.get("user"))) throw forbidden("Admins only");
    await next();
  });

  // Open disputes, oldest first, with evidence, AI results and the dispute reason on each job.
  app.get("/disputes", async (c) => {
    const user = c.get("user");
    const ctx = new WireContext(deps);
    const jobs = (await deps.store.listJobsNeedingAttention())
      .filter((j) => j.state === "DISPUTED")
      .sort((a, b) => (a.dispute?.openedAt ?? "").localeCompare(b.dispute?.openedAt ?? ""));
    return c.json(await Promise.all(jobs.map((j) => jobWire(ctx, j, user))));
  });

  return app;
}
