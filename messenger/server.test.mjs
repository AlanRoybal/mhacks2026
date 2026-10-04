import assert from "node:assert/strict";
import { createServer } from "node:http";
import { test } from "node:test";
import { createHandler, forwardInbound, senderAddress } from "./server.mjs";

const SECRET = "messenger-secret-0123456789";
const quiet = { error: () => {} };

async function withServer(handler, fn) {
  const server = createServer(handler);
  await new Promise((r) => server.listen(0, r));
  const url = `http://127.0.0.1:${server.address().port}`;
  try {
    await fn(url);
  } finally {
    server.close();
  }
}

test("/send needs the shared secret and an E.164 number", async () => {
  const sent = [];
  await withServer(createHandler({ secret: SECRET, sendText: async (to, text) => sent.push({ to, text }), log: quiet }), async (url) => {
    const post = (body, secret = SECRET) =>
      fetch(`${url}/send`, { method: "POST", headers: { "x-messenger-secret": secret }, body: JSON.stringify(body) });
    assert.equal((await post({ to: "+17345550100", text: "hi" }, "nope")).status, 401);
    assert.equal((await post({ to: "734-555-0100", text: "hi" })).status, 400);
    assert.equal((await post({ to: "+17345550100", text: "Your code is 123456" })).status, 200);
    assert.deepEqual(sent, [{ to: "+17345550100", text: "Your code is 123456" }]);
    assert.equal((await fetch(`${url}/health`)).status, 200);
  });
});

test("inbound 1:1 texts are forwarded to the backend; groups, outbound and non-text are skipped", async () => {
  async function* messages() {
    yield [{ type: "dm" }, { id: "m1", platform: "imessage", direction: "inbound", content: { type: "text", text: "Gate code 4417" }, sender: { id: "any;-;+17345550100" } }];
    yield [{ type: "group" }, { id: "m2", platform: "imessage", content: { type: "text", text: "group" }, sender: { id: "+1" } }];
    yield [{ type: "dm" }, { id: "m3", platform: "imessage", direction: "outbound", content: { type: "text", text: "echo" } }];
    yield [{ type: "dm" }, { id: "m4", platform: "imessage", content: { type: "attachment" }, sender: { id: "+1" } }];
  }
  const calls = [];
  let failures = 1;
  const fetchImpl = async (url, init) => {
    if (failures-- > 0) return new Response("", { status: 503 });
    calls.push({ url: String(url), secret: init.headers["x-messenger-secret"], body: JSON.parse(init.body) });
    return new Response("{}", { status: 202 });
  };
  await forwardInbound({ messages: messages(), apiUrl: "https://api.example.com", secret: SECRET, fetchImpl, log: quiet, retryDelayMs: 1 });
  assert.deepEqual(calls, [
    { url: "https://api.example.com/internal/imessage", secret: SECRET, body: { from: "+17345550100", text: "Gate code 4417", messageId: "m1" } },
  ]);
  assert.equal(senderAddress({ sender: { address: "+15551112222", id: "x" } }), "+15551112222");
});
