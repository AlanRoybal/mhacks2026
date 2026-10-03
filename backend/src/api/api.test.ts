import assert from "node:assert/strict";
import { test } from "node:test";
import { testDeps } from "../testing/harness.js";
import { createApp } from "./app.js";

async function call(app: ReturnType<typeof createApp>, method: string, path: string, body?: unknown, token?: string) {
  const res = await app.request(path, {
    method,
    headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { status: res.status, body: (await res.json()) as Record<string, any> };
}

test("health and auth routes are public; everything else needs a token", async () => {
  const app = createApp(testDeps());
  assert.equal((await call(app, "GET", "/health")).status, 200);
  const me = await call(app, "GET", "/me");
  assert.equal(me.status, 401);
  assert.equal(me.body.error, "unauthorized");
});

test("demo login returns a session for a stable persona", async () => {
  const app = createApp(testDeps());
  const first = await call(app, "POST", "/auth/demo", { handle: "judge", displayName: "Judge" });
  const again = await call(app, "POST", "/auth/demo", { handle: "judge" });
  assert.equal(first.status, 200);
  assert.equal(first.body.userId, again.body.userId);

  const me = await call(app, "GET", "/me", undefined, first.body.token);
  assert.equal(me.status, 200);
  assert.equal(me.body.displayName, "Judge");
  assert.equal(me.body.stats.reliability, 1);
});

test("device tokens are stored once per token", async () => {
  const app = createApp(testDeps());
  const { body } = await call(app, "POST", "/auth/demo", { handle: "worker1" });
  const token = "ab".repeat(32);
  await call(app, "POST", "/me/devices", { token, env: "sandbox" }, body.token);
  const res = await call(app, "POST", "/me/devices", { token, env: "sandbox" }, body.token);
  assert.equal(res.body.devices, 1);
});

test("validation errors use a stable error code", async () => {
  const app = createApp(testDeps());
  const res = await call(app, "POST", "/auth/demo", { handle: "Not Valid!" });
  assert.equal(res.status, 400);
  assert.equal(res.body.error, "invalid_request");
});

test("demo login is refused outside local dev unless DEMO_MODE is on", async () => {
  const app = createApp(testDeps({ STAGE: "prod", JWT_SECRET: "x".repeat(40) }));
  assert.equal((await call(app, "POST", "/auth/demo", { handle: "judge" })).status, 403);
});

test("local blob URLs accept a signed upload and reject a tampered one", async () => {
  const deps = testDeps();
  const app = createApp(deps);
  const upload = await deps.blobs.presignPut("proofs/j1/p1/c1-after.jpg", "image/jpeg");
  const path = upload.url.replace(deps.config.PUBLIC_BASE_URL, "");
  const ok = await app.request(path, { method: "PUT", headers: upload.headers, body: new Uint8Array([1, 2, 3]) });
  assert.equal(ok.status, 200);
  assert.equal((await deps.blobs.head("proofs/j1/p1/c1-after.jpg"))?.size, 3);
  const bad = await app.request(path.replace("sig=", "sig=0"), { method: "PUT", headers: upload.headers, body: new Uint8Array([1]) });
  assert.equal(bad.status, 403);
  const download = await app.request((await deps.blobs.presignGet("proofs/j1/p1/c1-after.jpg")).replace(deps.config.PUBLIC_BASE_URL, ""));
  assert.equal(download.headers.get("content-type"), "image/jpeg");
});
