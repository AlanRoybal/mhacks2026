import { Hono } from "hono";
import { z } from "zod";
import { MAX_FILE_BYTES } from "../../blobs/index.js";
import type { Deps } from "../../deps.js";
import { isValidTimeZone } from "../../domain/availability.js";
import { newId } from "../../domain/ids.js";
import { Category, LatLng, type SkillSourceKind, type User } from "../../domain/types.js";
import { badRequest, notFound } from "../../lib/errors.js";
import { activeSkills, deleteSkill, normName, readiness, refreshEmbedding, upsertSkill } from "../../services/twin.js";
import { updateUser } from "../../services/users.js";
import { parseBody, type AppEnv } from "../http.js";

// Labels the app shows next to each skill ("From LinkedIn").
const SOURCE_LABEL: Record<SkillSourceKind, string> = { linkedin: "LinkedIn", resume: "Résumé", email: "Email", user: "Added by you" };

const UPLOAD_KINDS = {
  resume_pdf: { contentType: "application/pdf", ext: "pdf" },
  linkedin_pdf: { contentType: "application/pdf", ext: "pdf" },
  linkedin_zip: { contentType: "application/zip", ext: "zip" },
} as const;
const UploadKind = z.enum(["resume_pdf", "linkedin_pdf", "linkedin_zip"]);

const HHMM = z.string().regex(/^([01]\d|2[0-3]):[0-5]\d$/);
const TimeZone = z.string().refine(isValidTimeZone, "Unknown time zone");

export function payoutsRequired(deps: Deps): boolean {
  return deps.config.PAYMENTS_PROVIDER === "stripe";
}

export function twinView(deps: Deps, user: User) {
  const t = user.twin;
  return {
    displayName: user.displayName,
    summary: t.summary,
    yearsExperience: t.yearsExperience,
    skills: activeSkills(t).map((s) => ({
      normName: s.normName,
      name: s.name,
      category: s.category ?? null,
      level: s.level,
      confidence: s.confidence,
      userEdited: s.userEdited,
      sources: s.sources.map((src) => ({ kind: src.kind, label: SOURCE_LABEL[src.kind], evidence: src.evidence })),
    })),
    roles: t.roles,
    education: t.education,
    certifications: t.certifications,
    ingest: { status: t.ingest.status, error: t.ingest.error ?? null, sources: t.ingest.sources, updatedAt: t.ingest.updatedAt },
    prefs: { ...user.prefs, quietHours: user.prefs.quietHours ?? null, base: user.prefs.base ?? null },
    availability: user.availability ?? null,
    readiness: readiness(user, { payoutsRequired: payoutsRequired(deps) }),
  };
}

export function twinRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const userId = (c: { get(k: "user"): User }) => c.get("user").userId;

  app.get("/", (c) => c.json(twinView(deps, c.get("user"))));

  // Step 1 of an import: get a presigned URL and PUT the file to it.
  app.post("/uploads", async (c) => {
    const { kind } = await parseBody(c, z.object({ kind: UploadKind }));
    const { contentType, ext } = UPLOAD_KINDS[kind];
    const blobKey = `uploads/${userId(c)}/${newId(deps.now().getTime())}.${ext}`;
    return c.json({ blobKey, upload: await deps.blobs.presignPut(blobKey, contentType) });
  });

  // Step 2: start the import. Poll GET /twin until ingest.status is "done" or "failed".
  app.post("/ingest", async (c) => {
    const body = await parseBody(c, z.object({ blobKey: z.string(), kind: UploadKind }));
    if (!body.blobKey.startsWith(`uploads/${userId(c)}/`)) throw notFound("Upload");
    const info = await deps.blobs.head(body.blobKey);
    if (!info) throw badRequest("Upload the file before starting the import", "upload_missing");
    if (info.size > MAX_FILE_BYTES) throw badRequest("That file is too large (20 MB max)", "too_large");
    const user = await updateUser(deps, userId(c), (u) => {
      u.twin.ingest = { ...u.twin.ingest, status: "processing", error: undefined, updatedAt: deps.now().toISOString() };
    });
    await deps.tasks.run({ kind: "task", name: "ingest_profile", userId: user.userId, blobKey: body.blobKey, sourceKind: body.kind });
    return c.json(twinView(deps, user), 202);
  });

  // Add a skill, edit one, or restore a deleted one (keyed by name, case-insensitive).
  app.post("/skills", async (c) => {
    const body = await parseBody(
      c,
      z.object({ name: z.string().trim().min(1).max(60), level: z.number().int().min(1).max(5).optional(), category: z.string().max(30).optional() }),
    );
    await updateUser(deps, userId(c), (u) => {
      u.twin = upsertSkill(u.twin, body, deps.now().toISOString());
    });
    return c.json(twinView(deps, await refreshEmbedding(deps, userId(c))));
  });

  app.delete("/skills/:normName", async (c) => {
    const key = normName(decodeURIComponent(c.req.param("normName")));
    await updateUser(deps, userId(c), (u) => {
      const next = deleteSkill(u.twin, key, deps.now().toISOString());
      if (!next) throw notFound("Skill");
      u.twin = next;
    });
    return c.json(twinView(deps, await refreshEmbedding(deps, userId(c))));
  });

  app.put("/prefs", async (c) => {
    const body = await parseBody(
      c,
      z
        .object({
          minPayCents: z.number().int().min(0).max(100_000),
          maxRadiusKm: z.number().min(0.5).max(100),
          blockedCategories: z.array(Category).max(10),
          remoteOk: z.boolean(),
          inPersonOk: z.boolean(),
          tz: TimeZone,
          quietHours: z.object({ start: HHMM, end: HHMM }).nullable(),
          base: LatLng.nullable(),
        })
        .partial(),
    );
    const user = await updateUser(deps, userId(c), (u) => {
      const { quietHours, base, ...rest } = body;
      Object.assign(u.prefs, rest);
      if (quietHours !== undefined) u.prefs.quietHours = quietHours ?? undefined;
      if (base !== undefined) u.prefs.base = base ?? undefined;
    });
    return c.json(twinView(deps, user));
  });

  // Calendar stays on the phone; the app uploads free/busy only.
  app.put("/availability", async (c) => {
    const body = await parseBody(
      c,
      z.object({
        tz: TimeZone,
        weekly: z
          .string()
          .regex(/^[01]{168}$/, "weekly must be 168 characters of 0/1 (Monday 00:00 first)")
          .optional(),
        busy: z.array(z.object({ start: z.string().datetime({ offset: true }), end: z.string().datetime({ offset: true }) })).max(500),
      }),
    );
    const user = await updateUser(deps, userId(c), (u) => {
      u.availability = {
        tz: body.tz,
        weekly: body.weekly,
        busy: body.busy.map((b) => ({ start: new Date(b.start).toISOString(), end: new Date(b.end).toISOString() })),
        updatedAt: deps.now().toISOString(),
      };
    });
    return c.json(twinView(deps, user));
  });

  return app;
}
