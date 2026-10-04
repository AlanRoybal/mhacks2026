// The live job session (SpacetimeDB): the worker's phone reports location and proof progress while the
// job is open, both phones register their Live Activities, and both read the live view.

import { Hono } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import type { Job, User } from "../../domain/types.js";
import { conflict, forbidden, notFound } from "../../lib/errors.js";
import { liveView, recordPing, recordProgress, registerActivity } from "../../services/live.js";
import { parseBody, type AppEnv } from "../http.js";
import { visibleJob } from "./jobs.js";

function requireWorkingJob(job: Job, user: User): void {
  if (job.workerId !== user.userId) throw forbidden("Only the assigned worker reports location for this job");
  if (job.state !== "IN_PROGRESS") throw conflict("invalid_transition", `The job is ${job.state}, not in progress`);
}

export function liveRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  const view = async (job: Job) => {
    const session = await deps.live.get(job.jobId);
    if (!session) throw notFound("Live session");
    return liveView(deps, session, await deps.live.events(job.jobId), job);
  };

  // GET /jobs/{id}/live: on-site time, phase, progress and recent events, for the poster or the worker.
  app.get("/:id/live", async (c) => {
    const job = await visibleJob(deps, c.get("user"), c.req.param("id"));
    return c.json(await view(job));
  });

  // A location fix while the job is open. SpacetimeDB decides whether it's on site.
  app.post("/:id/live/ping", async (c) => {
    const body = await parseBody(c, z.object({ latitude: z.number().min(-90).max(90), longitude: z.number().min(-180).max(180), accuracyM: z.number().nonnegative() }));
    const job = await visibleJob(deps, c.get("user"), c.req.param("id"));
    requireWorkingJob(job, c.get("user"));
    await recordPing(deps, job, body.latitude, body.longitude, body.accuracyM);
    return c.json(await view(job));
  });

  // How many checklist items have proof captured so far.
  app.post("/:id/live/progress", async (c) => {
    const body = await parseBody(c, z.object({ itemsDone: z.number().int().min(0).max(50) }));
    const job = await visibleJob(deps, c.get("user"), c.req.param("id"));
    requireWorkingJob(job, c.get("user"));
    await recordProgress(deps, job, body.itemsDone);
    return c.json(await view(job));
  });

  // A Live Activity's push token, so updates reach the Lock Screen while the app is closed.
  app.post("/:id/live/activity", async (c) => {
    const body = await parseBody(c, z.object({ token: z.string().regex(/^[0-9a-fA-F]{32,200}$/), env: z.enum(["sandbox", "production"]), role: z.enum(["worker", "poster"]) }));
    const user = c.get("user");
    const job = await visibleJob(deps, user, c.req.param("id"));
    if (body.role === "worker" ? job.workerId !== user.userId : job.posterId !== user.userId) throw forbidden("That isn't your role on this job");
    await registerActivity(deps, job, user, body.role, body.token.toLowerCase(), body.env);
    return c.body(null, 204);
  });

  return app;
}
