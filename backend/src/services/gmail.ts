// Gmail import: exchange the app's PKCE code, read a sample of recent sent mail, revoke the token.
// The token is never stored and only the trimmed text goes on to skill extraction.

import type { Deps } from "../deps.js";
import { badRequest } from "../lib/errors.js";

export const GMAIL_SCOPE = "https://www.googleapis.com/auth/gmail.readonly";
const GMAIL_API = "https://gmail.googleapis.com/gmail/v1/users/me";
const MAX_MESSAGES = 40;
const MAX_MESSAGE_CHARS = 1_500;
export const MAX_GMAIL_CHARS = 50_000;

interface GmailPart {
  mimeType?: string;
  body?: { data?: string };
  parts?: GmailPart[];
  headers?: { name: string; value: string }[];
}

export async function exchangeGoogleCode(deps: Deps, opts: { code: string; codeVerifier: string; redirectUri: string }): Promise<string> {
  const res = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "authorization_code",
      code: opts.code,
      code_verifier: opts.codeVerifier,
      redirect_uri: opts.redirectUri,
      client_id: deps.config.GOOGLE_CLIENT_ID ?? "",
    }),
  });
  if (!res.ok) {
    deps.log.warn("Google token exchange failed", { status: res.status, body: await res.text() });
    throw badRequest("Google sign-in didn't complete. Try connecting Gmail again.", "google_exchange_failed");
  }
  const { access_token, scope } = (await res.json()) as { access_token?: string; scope?: string };
  if (!access_token) throw badRequest("Google didn't return an access token.", "google_exchange_failed");
  if (!scope?.split(" ").includes(GMAIL_SCOPE)) {
    await revokeGoogleToken(access_token);
    throw badRequest("Allow Bounty to read your mail to import skills from Gmail.", "gmail_scope_denied");
  }
  return access_token;
}

export async function revokeGoogleToken(token: string): Promise<void> {
  await fetch("https://oauth2.googleapis.com/revoke", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ token }),
  }).catch(() => undefined);
}

const decode = (data: string) => Buffer.from(data, "base64url").toString("utf8");

function plainText(part: GmailPart): string {
  if (part.mimeType === "text/plain" && part.body?.data) return decode(part.body.data);
  for (const child of part.parts ?? []) {
    const text = plainText(child);
    if (text) return text;
  }
  if (part.mimeType === "text/html" && part.body?.data) return decode(part.body.data).replace(/<[^>]+>/g, " ");
  return "";
}

// Keeps what the person wrote: drops quoted replies, forwarded text and signatures' trailing noise.
export function ownWords(body: string): string {
  const lines: string[] = [];
  for (const line of body.replace(/\r/g, "").split("\n")) {
    if (/^On .+wrote:$/.test(line.trim()) || /^-{2,}\s*(Original|Forwarded) Message/i.test(line.trim()) || /^From: /.test(line)) break;
    if (line.startsWith(">")) continue;
    lines.push(line);
  }
  return lines
    .join("\n")
    .replace(/https?:\/\/\S+/g, "[link]")
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim()
    .slice(0, MAX_MESSAGE_CHARS);
}

async function gmail<T>(token: string, path: string): Promise<T> {
  const res = await fetch(`${GMAIL_API}/${path}`, { headers: { authorization: `Bearer ${token}` } });
  if (!res.ok) throw badRequest(`Gmail couldn't be read (${res.status}). Try again.`, "gmail_read_failed");
  return (await res.json()) as T;
}

// Subject and body of recent sent mail. No addresses: the skills come from what was written.
export async function readSentMail(token: string): Promise<string> {
  const list = await gmail<{ messages?: { id: string }[] }>(token, `messages?labelIds=SENT&maxResults=${MAX_MESSAGES}&q=${encodeURIComponent("newer_than:2y")}`);
  const ids = (list.messages ?? []).map((m) => m.id);
  const parts: string[] = [];
  for (let i = 0; i < ids.length; i += 10) {
    const batch = await Promise.all(ids.slice(i, i + 10).map((id) => gmail<{ payload?: GmailPart }>(token, `messages/${id}?format=full`)));
    for (const message of batch) {
      if (!message.payload) continue;
      const subject = message.payload.headers?.find((h) => h.name.toLowerCase() === "subject")?.value ?? "";
      const body = ownWords(plainText(message.payload));
      if (subject || body) parts.push(`Subject: ${subject}\n${body}`);
    }
  }
  return parts.join("\n\n---\n\n").slice(0, MAX_GMAIL_CHARS);
}
