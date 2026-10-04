// Bounty's iMessage bridge on Photon Spectrum (spectrum-ts, Stable docs).
//
//   POST /send {to, text}   the backend asks for a text (header x-messenger-secret)
//   GET  /health
//   inbound iMessages  →    POST $BOUNTY_API_URL/internal/imessage {from, text, messageId}
//
// It runs as a long-lived process because Spectrum keeps a gRPC stream open and renews its tokens; the
// backend runs on Lambda, which can freeze between requests. All product logic stays in the backend.
//
// Env: SPECTRUM_PROJECT_ID, SPECTRUM_PROJECT_SECRET (read by Spectrum), BOUNTY_API_URL, MESSENGER_SECRET, PORT.

import { timingSafeEqual } from "node:crypto";
import { createServer } from "node:http";
import { fileURLToPath } from "node:url";

const MAX_BODY = 16 * 1024;

const sameSecret = (given, expected) =>
  typeof given === "string" && given.length === expected.length && timingSafeEqual(Buffer.from(given), Buffer.from(expected));

async function readJson(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw Object.assign(new Error("body too large"), { status: 413 });
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8") || "{}");
  } catch {
    throw Object.assign(new Error("invalid JSON"), { status: 400 });
  }
}

function reply(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

/** HTTP handler; `sendText(to, text)` does the actual iMessage send. */
export function createHandler({ secret, sendText, log = console }) {
  return async (req, res) => {
    try {
      if (req.method === "GET" && req.url === "/health") return reply(res, 200, { ok: true });
      if (req.method !== "POST" || req.url !== "/send") return reply(res, 404, { error: "not_found" });
      if (!sameSecret(req.headers["x-messenger-secret"], secret)) return reply(res, 401, { error: "unauthorized" });
      const { to, text } = await readJson(req);
      if (typeof to !== "string" || !/^\+\d{8,15}$/.test(to) || typeof text !== "string" || !text.trim() || text.length > 2000) {
        return reply(res, 400, { error: "bad_request", message: "Need { to: E.164 number, text: 1-2000 chars }" });
      }
      await sendText(to, text);
      return reply(res, 200, { sent: true });
    } catch (error) {
      log.error("send failed", error);
      return reply(res, error.status ?? 502, { error: "send_failed", message: String(error.message ?? error) });
    }
  };
}

// "+17345550100", "any;-;+17345550100" or an email → the handle the backend links phones by.
export function senderAddress(message) {
  const id = message?.sender?.address ?? message?.sender?.id ?? "";
  return id.includes(";-;") ? id.split(";-;").pop() : id;
}

/** Forwards each inbound 1:1 iMessage text to the backend, retrying briefly if it's unreachable. */
export async function forwardInbound({ messages, apiUrl, secret, isGroup = (space) => space?.type === "group", fetchImpl = fetch, log = console, retryDelayMs = 1000 }) {
  for await (const [space, message] of messages) {
    if (message.platform !== "imessage" || message.direction === "outbound") continue;
    if (message.content?.type !== "text" || isGroup(space)) continue;
    const body = JSON.stringify({ from: senderAddress(message), text: message.content.text, messageId: message.id });
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        const res = await fetchImpl(new URL("/internal/imessage", apiUrl), {
          method: "POST",
          headers: { "content-type": "application/json", "x-messenger-secret": secret },
          body,
        });
        if (res.ok || (res.status >= 400 && res.status < 500)) {
          if (!res.ok) log.error(`backend refused message ${message.id}: ${res.status}`);
          break;
        }
        throw new Error(`backend ${res.status}`);
      } catch (error) {
        if (attempt === 3) log.error(`dropped message ${message.id}`, error);
        else await new Promise((r) => setTimeout(r, retryDelayMs * attempt));
      }
    }
  }
}

async function main() {
  const { BOUNTY_API_URL: apiUrl, MESSENGER_SECRET: secret, PORT = "4343" } = process.env;
  if (!apiUrl || !secret || secret.length < 16) throw new Error("Set BOUNTY_API_URL and MESSENGER_SECRET (16+ characters)");
  const { Spectrum } = await import("@spectrum-ts/core");
  const { imessage } = await import("@spectrum-ts/imessage");
  // Project ID and secret come from SPECTRUM_PROJECT_ID / SPECTRUM_PROJECT_SECRET.
  const app = await Spectrum({ providers: [imessage.config()] });
  const im = imessage(app);

  // One DM space per number; creating it again would count against the daily new-conversation quota.
  const spaces = new Map();
  const sendText = async (to, text) => {
    let space = spaces.get(to);
    if (!space) {
      space = await im.space.create(await im.user(to));
      spaces.set(to, space);
    }
    await space.send(text);
  };

  const server = createServer(createHandler({ secret, sendText }));
  server.listen(Number(PORT), () => console.log(`messenger listening on :${PORT}, forwarding to ${apiUrl}`));
  const stop = async () => {
    server.close();
    await app.stop();
    process.exit(0);
  };
  process.on("SIGTERM", stop);
  process.on("SIGINT", stop);
  // iMessage spaces carry type "dm" | "group" once narrowed.
  await forwardInbound({ messages: app.messages, apiUrl, secret, isGroup: (space) => imessage(space).type === "group" });
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error);
    process.exit(1);
  });
}
