import { Hono } from "hono";
import { z } from "zod";
import { MAX_FILE_BYTES } from "../../blobs/index.js";
import type { Deps } from "../../deps.js";
import { isValidTimeZone } from "../../domain/availability.js";
import { Category, type SkillSourceKind, type User } from "../../domain/types.js";
import { badRequest, notFound } from "../../lib/errors.js";
import { activeSkills, deleteSkill, normName, readiness, refreshEmbedding, upsertSkill } from "../../services/twin.js";
import { updateUser } from "../../services/users.js";
import { parseBody, type AppEnv } from "../http.js";
import { kmToMiles, milesToKm, wireDate } from "../wire.js";
import { ownedUploadKey } from "./uploads.js";

// Labels the app shows next to each skill ("From LinkedIn").
const SOURCE_LABEL: Record<SkillSourceKind, string> = { linkedin: "LinkedIn", resume: "Résumé", email: "Email", user: "Added by you" };

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
    ingest: { status: t.ingest.status, error: t.ingest.error ?? null, sources: t.ingest.sources, updatedAt: wireDate(t.ingest.updatedAt) },
    // Same units as jobs: dollars, miles, { latitude, longitude }.
    prefs: {
      minPay: user.prefs.minPayCents / 100,
      maxRadiusMiles: kmToMiles(user.prefs.maxRadiusKm),
      blockedCategories: user.prefs.blockedCategories,
      remoteOk: user.prefs.remoteOk,
      inPersonOk: user.prefs.inPersonOk,
      tz: user.prefs.tz,
      quietHours: user.prefs.quietHours ?? null,
      base: user.prefs.base ? { latitude: user.prefs.base.lat, longitude: user.prefs.base.lng } : null,
    },
    availability: user.availability
      ? {
          tz: user.availability.tz,
          weekly: user.availability.weekly ?? null,
          busy: user.availability.busy.map((b) => ({ start: wireDate(b.start), end: wireDate(b.end) })),
          updatedAt: wireDate(user.availability.updatedAt),
        }
      : null,
    readiness: readiness(user, { payoutsRequired: payoutsRequired(deps) }),
  };
}

export function twinRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const userId = (c: { get(k: "user"): User }) => c.get("user").userId;

  app.get("/", (c) => c.json(twinView(deps, c.get("user"))));

  // Import a résumé or LinkedIn file uploaded through /uploads/presign (application/pdf or application/zip).
  // Poll GET /twin until ingest.status is "done" or "failed".
  app.post("/ingest", async (c) => {
    const body = await parseBody(c, z.object({ blobKey: z.string().optional(), fileURL: z.string().optional(), kind: UploadKind }));
    const blobKey = ownedUploadKey(deps, userId(c), body);
    const info = await deps.blobs.head(blobKey);
    if (!info) throw badRequest("Upload the file before starting the import", "upload_missing");
    if (info.size > MAX_FILE_BYTES) throw badRequest("That file is too large (20 MB max)", "too_large");
    const user = await updateUser(deps, userId(c), (u) => {
      u.twin.ingest = { ...u.twin.ingest, status: "processing", error: undefined, updatedAt: deps.now().toISOString() };
    });
    await deps.tasks.run({ kind: "task", name: "ingest_profile", userId: user.userId, blobKey, sourceKind: body.kind });
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
    // Hono has already decoded the path parameter.
    const key = normName(c.req.param("normName"));
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
          // Dollars, like payAmount.
          minPay: z.number().min(0).max(1000),
          maxRadiusMiles: z.number().min(0.5).max(60),
          blockedCategories: z.array(Category).max(10),
          remoteOk: z.boolean(),
          inPersonOk: z.boolean(),
          tz: TimeZone,
          quietHours: z.object({ start: HHMM, end: HHMM }).nullable(),
          // Where distance is measured from; the app sends the device location.
          base: z.object({ latitude: z.number().min(-90).max(90), longitude: z.number().min(-180).max(180) }).nullable(),
        })
        .partial(),
    );
    const user = await updateUser(deps, userId(c), (u) => {
      if (body.minPay !== undefined) u.prefs.minPayCents = Math.round(body.minPay * 100);
      if (body.maxRadiusMiles !== undefined) u.prefs.maxRadiusKm = milesToKm(body.maxRadiusMiles);
      if (body.blockedCategories !== undefined) u.prefs.blockedCategories = body.blockedCategories;
      if (body.remoteOk !== undefined) u.prefs.remoteOk = body.remoteOk;
      if (body.inPersonOk !== undefined) u.prefs.inPersonOk = body.inPersonOk;
      if (body.tz !== undefined) u.prefs.tz = body.tz;
      if (body.quietHours !== undefined) u.prefs.quietHours = body.quietHours ?? undefined;
      if (body.base !== undefined) u.prefs.base = body.base ? { lat: body.base.latitude, lng: body.base.longitude } : undefined;
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
