import { timingSafeEqual } from "node:crypto";
import { Hono } from "hono";
import { z } from "zod";
import type { Deps } from "../../deps.js";
import { AppError, badRequest, conflict, forbidden, unauthorized } from "../../lib/errors.js";
import { getJobOrThrow } from "../../services/jobs.js";
import { THREAD_STATES, threadView, workerMessage } from "../../services/thread.js";
import { parseBody, type AppEnv } from "../http.js";

// POST /internal/imessage: the messenger service (messenger/) forwards each inbound iMessage here.
// Authenticated with MESSENGER_SECRET; the twin's reply runs in a background task.
export function messengerRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  app.post("/imessage", async (c) => {
    const expected = deps.config.MESSENGER_SECRET;
    const given = c.req.header("x-messenger-secret") ?? "";
    if (!expected || given.length !== expected.length || !timingSafeEqual(Buffer.from(given), Buffer.from(expected))) throw unauthorized("Bad messenger secret");
    const body = await parseBody(c, z.object({ from: z.string().min(3).max(40), text: z.string().max(4000), messageId: z.string().min(1).max(200) }));
    await deps.tasks.run({ kind: "task", name: "thread_inbound", ...body });
    return c.json({ accepted: true }, 202);
  });
  return app;
}

// GET /jobs/:id/thread (poster or worker) and POST /jobs/:id/thread (worker → poster, relayed by the twin).
export function threadRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.get("/:id/thread", async (c) => {
    const user = c.get("user");
    const job = await getJobOrThrow(deps, c.req.param("id"));
    if (job.posterId !== user.userId && job.workerId !== user.userId) throw forbidden("Not your job");
    return c.json(await threadView(deps, job, user));
  });

  app.post("/:id/thread", async (c) => {
    const user = c.get("user");
    const body = await parseBody(c, z.object({ text: z.string().trim().min(1).max(600) }));
    const job = await getJobOrThrow(deps, c.req.param("id"));
    if (job.workerId !== user.userId) throw forbidden("Only the assigned worker can message the poster");
    if (!THREAD_STATES.has(job.state)) throw conflict("thread_closed", "This job's conversation has ended");
    if (!deps.messenger.enabled) throw new AppError(501, "texts_not_configured", "Text messages aren't set up on this server.");
    try {
      await workerMessage(deps, job, user, body.text);
    } catch (error) {
      if (error instanceof Error && error.message === "poster_unreachable") throw badRequest("The poster hasn't turned on texts, so your twin can't reach them.", "poster_unreachable");
      throw error;
    }
    return c.json(await threadView(deps, job, user));
  });

  return app;
}
