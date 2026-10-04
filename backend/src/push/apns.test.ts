import { exportPKCS8, generateKeyPair } from "jose";
import assert from "node:assert/strict";
import { createServer, type Http2Session, type ServerHttp2Stream } from "node:http2";
import type { AddressInfo } from "node:net";
import { test } from "node:test";
import type { User } from "../domain/types.js";
import { silentLogger } from "../lib/log.js";
import { ApnsSender } from "./apns.js";

test("a hung APNs connection is dropped and the push is retried on a fresh one", async () => {
  const sessions = new Set<Http2Session>();
  let requests = 0;
  const server = createServer();
  server.on("session", (s) => sessions.add(s));
  server.on("stream", (stream: ServerHttp2Stream, headers) => {
    requests++;
    // The first request never gets an answer, like a connection that died while Lambda was frozen.
    if (requests === 1) return;
    assert.equal(headers["apns-topic"], "com.example.app");
    assert.match(String(headers.authorization), /^bearer /);
    stream.respond({ ":status": 200 });
    stream.end();
  });
  await new Promise<void>((resolve) => server.listen(0, resolve));
  const url = `http://localhost:${(server.address() as AddressInfo).port}`;

  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  const apns = new ApnsSender(
    { keyId: "KEY", teamId: "TEAM", keyP8: await exportPKCS8(privateKey), bundleId: "com.example.app", hosts: { sandbox: url, production: url }, timeoutMs: 200 },
    silentLogger,
  );
  const user = { userId: "u1", devices: [{ token: "ab".repeat(32), env: "sandbox", updatedAt: "" }] } as unknown as User;

  const result = await apns.send(user, { title: "t", body: "b", type: "offer", jobId: "j1" });
  assert.deepEqual(result, { deadTokens: [] });
  assert.equal(requests, 2);
  assert.equal(sessions.size, 2, "the retry used a new connection");

  for (const s of sessions) s.destroy();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});
