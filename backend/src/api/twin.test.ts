import { strToU8, zipSync } from "fflate";
import assert from "node:assert/strict";
import { test } from "node:test";
import { mergeExtraction } from "../services/twin.js";
import { newUser } from "../services/users.js";
import { testDeps, type TestDeps } from "../testing/harness.js";
import { createApp } from "./app.js";

type App = ReturnType<typeof createApp>;

async function call(app: App, method: string, path: string, token: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, body: (await res.json()) as Record<string, any> };
}

async function login(app: App, handle: string): Promise<string> {
  const res = await app.request("/auth/demo", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ handle }) });
  return ((await res.json()) as { token: string }).token;
}

async function upload(deps: TestDeps, app: App, token: string, kind: string, bytes: Uint8Array) {
  const contentType = kind === "linkedin_zip" ? "application/zip" : "application/pdf";
  const { body } = await call(app, "POST", "/uploads/presign", token, { contentType });
  const res = await app.request(body.uploadURL.replace(deps.config.PUBLIC_BASE_URL, ""), { method: "PUT", headers: body.headers, body: bytes });
  assert.equal(res.status, 200);
  return body.blobKey as string;
}

test("a new twin lists what blocks matching", async () => {
  const app = createApp(testDeps());
  const token = await login(app, "worker1");
  const { body } = await call(app, "GET", "/twin", token);
  assert.equal(body.readiness.ready, false);
  assert.deepEqual(body.readiness.missing, ["skills", "notifications"]);
});

test("skills can be added, deleted and restored by hand", async () => {
  const app = createApp(testDeps());
  const token = await login(app, "worker1");
  const added = await call(app, "POST", "/twin/skills", token, { name: "Calculus tutoring", level: 4 });
  assert.equal(added.body.skills[0].sources[0].label, "Added by you");
  const deleted = await call(app, "DELETE", "/twin/skills/calculus%20tutoring", token);
  assert.equal(deleted.body.skills.length, 0);
  const restored = await call(app, "POST", "/twin/skills", token, { name: "calculus tutoring" });
  assert.equal(restored.body.skills.length, 1);
  assert.equal((await call(app, "DELETE", "/twin/skills/nope", token)).status, 404);
});

test("importing a LinkedIn export adds sourced skills and an embedding", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "worker1");
  const zip = zipSync({ "Skills.csv": strToU8("Name\nLogo Design\nIllustration\n"), "Other.csv": strToU8("ignored") });
  const blobKey = await upload(deps, app, token, "linkedin_zip", zip);

  const started = await call(app, "POST", "/twin/ingest", token, { blobKey, kind: "linkedin_zip" });
  assert.equal(started.status, 202);
  assert.equal(started.body.ingest.status, "processing");
  await deps.settle();

  const { body } = await call(app, "GET", "/twin", token);
  assert.equal(body.ingest.status, "done");
  assert.deepEqual(body.skills.map((s: { name: string }) => s.name).sort(), ["Illustration", "Logo Design"]);
  assert.equal(body.skills[0].sources[0].label, "LinkedIn");
  const user = await deps.store.getUser((await call(app, "GET", "/me", token)).body.userId);
  assert.ok(user?.twin.embedding?.length);
});

test("a bad upload marks the import failed with a readable message", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "worker1");
  const blobKey = await upload(deps, app, token, "linkedin_zip", strToU8("not a zip"));
  await call(app, "POST", "/twin/ingest", token, { blobKey, kind: "linkedin_zip" });
  await deps.settle();
  const { body } = await call(app, "GET", "/twin", token);
  assert.equal(body.ingest.status, "failed");
  assert.match(body.ingest.error, /ZIP/);
});

test("users cannot import someone else's upload", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const alice = await login(app, "alice");
  const bob = await login(app, "bob");
  const blobKey = await upload(deps, app, alice, "resume_pdf", strToU8("%PDF-1.4"));
  assert.equal((await call(app, "POST", "/twin/ingest", bob, { blobKey, kind: "resume_pdf" })).status, 400);
});

test("re-imports never resurrect deleted skills or override edits", () => {
  const now = "2026-10-04T15:00:00.000Z";
  const twin = newUser({ displayName: "W" }, new Date(now)).twin;
  twin.skills = [
    { normName: "logo design", name: "Logo design", level: 5, confidence: 1, sources: [{ kind: "user", evidence: "Added by you" }], userEdited: true, deleted: false },
    { normName: "welding", name: "Welding", level: 2, confidence: 0.5, sources: [{ kind: "resume", evidence: "x" }], userEdited: true, deleted: true },
  ];
  const merged = mergeExtraction(
    twin,
    {
      summary: "Designer.",
      yearsExperience: 3,
      skills: [
        { name: "Logo Design", category: "design", level: 2, confidence: 0.7, evidence: "Designer at Acme" },
        { name: "Welding", category: "other", level: 4, confidence: 0.9, evidence: "Weld shop" },
        { name: "Branding", category: "design", level: 3, confidence: 0.8, evidence: "Brand work" },
      ],
      roles: [],
      education: [],
      certifications: [],
    },
    "linkedin",
    now,
  );
  const byName = new Map(merged.skills.map((s) => [s.normName, s]));
  assert.equal(byName.get("logo design")?.level, 5);
  assert.equal(byName.get("logo design")?.sources.length, 2);
  assert.equal(byName.get("welding")?.deleted, true);
  assert.equal(byName.get("branding")?.sources[0]?.kind, "linkedin");
});

test("preferences use the same units as jobs: dollars, miles, latitude/longitude", async () => {
  const app = createApp(testDeps());
  const token = await login(app, "worker1");
  const { body } = await call(app, "PUT", "/twin/prefs", token, {
    minPay: 15,
    maxRadiusMiles: 5,
    base: { latitude: 42.28, longitude: -83.74 },
    quietHours: { start: "22:00", end: "07:00" },
  });
  assert.equal(body.prefs.minPay, 15);
  assert.equal(body.prefs.maxRadiusMiles, 5);
  assert.deepEqual(body.prefs.base, { latitude: 42.28, longitude: -83.74 });
  assert.match(body.ingest.updatedAt, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);
  const bad = await call(app, "PUT", "/twin/prefs", token, { quietHours: { start: "25:00", end: "07:00" } });
  assert.equal(bad.status, 400);
});

test("oversized entries in a LinkedIn ZIP are never expanded", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "worker1");
  // 50 MB of one repeated character compresses to a few dozen KB.
  const bomb = zipSync({ "Skills.csv": new Uint8Array(50_000_000).fill(65) }, { level: 9 });
  assert.ok(bomb.length < 200_000);
  const blobKey = await upload(deps, app, token, "linkedin_zip", bomb);
  await call(app, "POST", "/twin/ingest", token, { blobKey, kind: "linkedin_zip" });
  await deps.settle();
  const { body } = await call(app, "GET", "/twin", token);
  assert.equal(body.ingest.status, "failed");
});
