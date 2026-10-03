import assert from "node:assert/strict";
import { test } from "node:test";
import { testDeps, type TestDeps } from "../testing/harness.js";
import { createApp } from "./app.js";

type App = ReturnType<typeof createApp>;
type Json = Record<string, any>;

async function call(app: App, method: string, path: string, token: string, body?: unknown) {
  const res = await app.request(path, {
    method,
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, body: (res.status === 204 ? {} : await res.json()) as Json };
}

async function login(app: App, handle: string): Promise<string> {
  const res = await app.request("/auth/demo", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ handle }) });
  return ((await res.json()) as { token: string }).token;
}

const ISO_NO_MS = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/;

// The body NewJobDraft encodes to on iOS (with .iso8601 dates).
function newJobDraft(deps: TestDeps, overrides: Json = {}) {
  return {
    title: "Sketch a logo for a coffee shop",
    description: 'Paper sketch of a logo for "Bean There." Any style.',
    category: "DESIGN",
    location: { latitude: 42.2808, longitude: -83.743, address: "State St, Ann Arbor, MI" },
    deadline: new Date(deps.now().getTime() + 6 * 3600_000).toISOString().replace(/\.\d{3}Z$/, "Z"),
    payAmount: 15,
    currency: "USD",
    posterPhotos: [],
    ...overrides,
  };
}

test("creating a job returns the iOS Job shape with a generated checklist", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "poster");

  const presign = await call(app, "POST", "/uploads/presign", token, { contentType: "image/jpeg" });
  assert.equal(presign.status, 200);
  await app.request(presign.body.uploadURL.replace(deps.config.PUBLIC_BASE_URL, ""), { method: "PUT", headers: presign.body.headers, body: new Uint8Array([1]) });

  const { status, body: job } = await call(app, "POST", "/jobs/create", token, newJobDraft(deps, { posterPhotos: [presign.body.fileURL] }));
  assert.equal(status, 201);
  assert.equal(job.status, "DRAFT");
  assert.equal(job.category, "DESIGN");
  assert.equal(job.payAmount, 15);
  assert.equal(job.currency, "USD");
  assert.deepEqual(job.location, { latitude: 42.2808, longitude: -83.743, address: "State St, Ann Arbor, MI" });
  assert.match(job.deadline, ISO_NO_MS);
  assert.match(job.createdAt, ISO_NO_MS);
  assert.deepEqual(job.posterPhotos, [presign.body.fileURL]);
  assert.deepEqual(job.verdicts, []);
  assert.equal(job.worker, null);
  assert.equal(job.feeAmount, 1.5);
  assert.equal(job.totalAmount, 16.5);
  assert.deepEqual(job.allowedActions, ["edit_checklist", "fund", "delete"]);
  assert.ok(job.checklist.length >= 2);
  for (const item of job.checklist) assert.ok(["PHOTO", "CHECK_IN", "LINK", "FILE"].includes(item.evidenceType));
  assert.ok(job.checklist.some((i: Json) => i.evidenceType === "CHECK_IN"), "in-person jobs always get a check-in");

  const photo = await app.request(job.posterPhotos[0].replace(deps.config.PUBLIC_BASE_URL, ""));
  assert.equal(photo.status, 302, "file URLs redirect to a short-lived download");
});

test("remote jobs have location null and no check-in item", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "poster");
  const { body: job } = await call(app, "POST", "/jobs", token, newJobDraft(deps, { location: null, category: "TECHNOLOGY" }));
  assert.equal(job.location, null);
  assert.ok(!job.checklist.some((i: Json) => i.evidenceType === "CHECK_IN"));

  // Swift's JSONEncoder omits nil optionals, so a remote NewJobDraft has no location key at all.
  const { location: _omitted, ...swiftBody } = newJobDraft(deps, { category: "TECHNOLOGY" });
  const fromSwift = await call(app, "POST", "/jobs", token, swiftBody);
  assert.equal(fromSwift.status, 201);
  assert.equal(fromSwift.body.location, null);
});

test("checklist edits keep app-made ids and fill omitted fields from before", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "poster");
  const { body: job } = await call(app, "POST", "/jobs", token, newJobDraft(deps));
  const first = job.checklist[0];
  const uuid = "6F9619FF-8B86-D011-B42D-00CF4FC964FF";
  const edited = await call(app, "PUT", `/jobs/${job.id}/checklist`, token, {
    checklist: [
      { id: first.id, text: "Logo shows a coffee cup", evidenceType: "PHOTO", photoCount: 2 },
      { id: uuid, text: "Shop name is legible", evidenceType: "PHOTO" },
    ],
  });
  assert.equal(edited.status, 200);
  const items = edited.body.checklist as Json[];
  assert.equal(items[0]?.id, first.id);
  assert.equal(items[0]?.photoCount, 2);
  assert.equal(items[0]?.angleHint, first.angleHint, "angleHint survives an edit that omits it");
  assert.equal(items[1]?.id, uuid);
  assert.ok(items.some((i) => i.evidenceType === "CHECK_IN"), "check-in is kept for in-person jobs");
});

test("drafts list under /jobs/mine, can be deleted, and are private", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const poster = await login(app, "poster");
  const stranger = await login(app, "stranger");
  const { body: job } = await call(app, "POST", "/jobs", poster, newJobDraft(deps));

  const mine = await call(app, "GET", "/jobs/mine", poster);
  assert.deepEqual(
    (mine.body as unknown as Json[]).map((j) => j.id),
    [job.id],
  );
  assert.equal((await call(app, "GET", `/jobs/${job.id}`, stranger)).status, 404);
  assert.equal((await call(app, "PUT", `/jobs/${job.id}/checklist`, stranger, [{ text: "x", evidenceType: "PHOTO" }])).status, 403);

  const quote = await call(app, "GET", `/jobs/${job.id}/quote`, poster);
  assert.deepEqual(quote.body, { payAmount: 15, feeAmount: 1.5, totalAmount: 16.5, currency: "USD" });

  const timeline = await call(app, "GET", `/jobs/${job.id}/timeline`, poster);
  assert.equal((timeline.body as unknown as Json[])[0]?.label, "Job created");

  assert.equal((await call(app, "DELETE", `/jobs/${job.id}`, poster)).status, 204);
  assert.equal((await call(app, "GET", `/jobs/${job.id}`, poster)).status, 404);
});

test("bad drafts are rejected with readable errors", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "poster");
  const tooCheap = await call(app, "POST", "/jobs", token, newJobDraft(deps, { payAmount: 2 }));
  assert.equal(tooCheap.status, 400);
  assert.equal(tooCheap.body.error.message, "Pay must be between $5 and $1000");
  const soon = await call(app, "POST", "/jobs", token, newJobDraft(deps, { deadline: new Date(deps.now().getTime() + 60_000).toISOString() }));
  assert.equal(soon.status, 400);
  const unknownCategory = await call(app, "POST", "/jobs", token, newJobDraft(deps, { category: "design" }));
  assert.equal(unknownCategory.body.error.code, "invalid_request");
  const foreignPhoto = await call(app, "POST", "/jobs", token, newJobDraft(deps, { posterPhotos: ["https://example.com/x.jpg"] }));
  assert.equal(foreignPhoto.body.error.code, "unknown_upload");
});

test("PATCH keeps fields it doesn't mention; terms use the posting deadline rules", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "poster");
  const { body: job } = await call(app, "POST", "/jobs", token, newJobDraft(deps, { currency: "USDC" }));
  const patched = await call(app, "PATCH", `/jobs/${job.id}`, token, { title: "A better title" });
  assert.equal(patched.body.title, "A better title");
  assert.equal(patched.body.currency, "USDC", "currency is not reset to its default");

  const remote = await call(app, "POST", "/jobs", token, newJobDraft(deps, { location: null }));
  await call(app, "POST", `/demo/jobs/${remote.body.id}/fund`, token);
  const tooSoon = await call(app, "PATCH", `/jobs/${remote.body.id}/terms`, token, { deadline: new Date(deps.now().getTime() + 60_000).toISOString() });
  assert.equal(tooSoon.status, 400);
});

test("skills with % in the name can be deleted", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const token = await login(app, "worker");
  await call(app, "POST", "/twin/skills", token, { name: "100% uptime ops" });
  const deleted = await call(app, "DELETE", `/twin/skills/${encodeURIComponent("100% uptime ops")}`, token);
  assert.equal(deleted.status, 200);
  assert.equal(deleted.body.skills.length, 0);
});
