// Routes in the shape TwinKit (Packages/TwinKit on main, used by the iosA app) calls: snake_case
// bodies, the paths its services hard-code, and its DTOs. They are adapters over the same services
// as the camelCase routes, so behavior is identical. Errors use TwinKit's { error: { code, message } }.

import { Hono } from "hono";
import { z } from "zod";
import type { ProfileSourceKind } from "../../ai/index.js";
import { MAX_FILE_BYTES } from "../../blobs/index.js";
import type { Deps } from "../../deps.js";
import { newId } from "../../domain/ids.js";
import type { User } from "../../domain/types.js";
import { badRequest } from "../../lib/errors.js";
import { activeSkills, refreshEmbedding, replaceSkills } from "../../services/twin.js";
import { updateUser } from "../../services/users.js";
import { parseBody, type AppEnv } from "../http.js";
import { wireDate } from "../wire.js";
import { respondToOffer } from "./offers.js";
import { startIngest } from "./twin.js";
import { ownedUploadKey } from "./uploads.js";

// TwinKit's ProfileDocumentSource -> our import kinds.
const SOURCES: Record<string, ProfileSourceKind> = { resume: "resume_pdf", linkedin_pdf: "linkedin_pdf", linkedin_export: "linkedin_zip" };
const UPLOAD_TYPES: Record<string, string> = { "application/pdf": "pdf", "application/zip": "zip", "application/x-zip-compressed": "zip" };

// TwinKit's TwinProfile.
export function twinProfileDto(user: User) {
  const t = user.twin;
  return {
    user_id: user.userId,
    headline: t.summary || null,
    skills: activeSkills(t).map((s) => ({
      id: s.normName,
      name: s.name,
      confidence: s.confidence,
      source: s.sources[0]?.kind ?? "user",
      years_of_experience: null,
    })),
    roles: t.roles.map((r) => (r.org ? `${r.title}, ${r.org}` : r.title)),
    education: t.education.map((e) => [e.degree, e.field, e.school].filter(Boolean).join(", ")),
    certifications: t.certifications,
    updated_at: wireDate(t.updatedAt),
  };
}

export function twinKitRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const me = (c: { get(k: "user"): User }) => c.get("user").userId;

  // TwinProfileService.profile()
  app.get("/profile/twin", (c) => c.json(twinProfileDto(c.get("user"))));

  // TwinProfileService.update(skills:): the full edited list.
  app.put("/profile/twin/skills", async (c) => {
    const body = await parseBody(
      c,
      z.object({
        skills: z.array(z.object({ id: z.string().optional(), name: z.string().trim().min(1).max(60), confidence: z.number().min(0).max(1).optional() })).max(80),
      }),
    );
    await updateUser(deps, me(c), (u) => {
      u.twin = replaceSkills(u.twin, body.skills, deps.now().toISOString());
    });
    return c.json(twinProfileDto(await refreshEmbedding(deps, me(c))));
  });

  // ProfileIngestionService step 1: where to PUT the document.
  app.post("/profile/upload-url", async (c) => {
    const body = await parseBody(
      c,
      z.object({ file_name: z.string().max(200), content_type: z.string(), byte_count: z.number().int().min(0), source: z.enum(["resume", "linkedin_pdf", "linkedin_export"]) }),
    );
    const ext = UPLOAD_TYPES[body.content_type];
    if (!ext) throw badRequest("Upload a PDF résumé, a LinkedIn PDF, or the LinkedIn export ZIP", "unsupported_type");
    if (body.byte_count > MAX_FILE_BYTES) throw badRequest("That file is too large (20 MB max)", "too_large");
    const objectKey = `uploads/${me(c)}/${newId(deps.now().getTime())}.${ext}`;
    const upload = await deps.blobs.presignPut(objectKey, ext === "pdf" ? "application/pdf" : "application/zip");
    return c.json({ upload_url: upload.url, object_key: objectKey, headers: upload.headers });
  });

  // ProfileIngestionService step 2: import it. Poll GET /profile/twin (or GET /twin for status).
  app.post("/profile/ingest", async (c) => {
    const body = await parseBody(c, z.object({ object_key: z.string(), source: z.enum(["resume", "linkedin_pdf", "linkedin_export"]) }));
    const kind = SOURCES[body.source] ?? "resume_pdf";
    const user = await startIngest(deps, me(c), ownedUploadKey(deps, me(c), { blobKey: body.object_key }), kind);
    return c.json({ ingestion_id: `${user.userId}:${Date.parse(user.twin.ingest.updatedAt)}`, status: user.twin.ingest.status }, 202);
  });

  // AvailabilityService.sync(): busy blocks only; calendar details never leave the phone.
  app.put("/profile/availability", async (c) => {
    const body = await parseBody(
      c,
      z.object({
        generated_at: z.string().datetime({ offset: true }).optional(),
        window_start: z.string().datetime({ offset: true }).optional(),
        window_end: z.string().datetime({ offset: true }).optional(),
        busy_blocks: z.array(z.object({ start: z.string().datetime({ offset: true }), end: z.string().datetime({ offset: true }) })).max(1000),
      }),
    );
    await updateUser(deps, me(c), (u) => {
      u.availability = {
        tz: u.availability?.tz ?? u.prefs.tz,
        weekly: u.availability?.weekly,
        busy: body.busy_blocks.map((b) => ({ start: new Date(b.start).toISOString(), end: new Date(b.end).toISOString() })),
        updatedAt: deps.now().toISOString(),
      };
    });
    return c.body(null, 204);
  });

  // OfferService.respond(to:decision:)
  app.post("/offers/:id/respond", async (c) => {
    const body = await parseBody(c, z.object({ decision: z.enum(["accept", "decline"]) }));
    const { offer, job } = await respondToOffer(deps, c.get("user"), c.req.param("id"), body.decision === "accept");
    return c.json({ offer_id: offer.offerId, job_id: job.jobId, status: job.state });
  });

  return app;
}
