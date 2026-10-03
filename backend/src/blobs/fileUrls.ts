// Stable URLs for uploaded files: <PUBLIC_BASE_URL>/files/<key>?sig=<hmac>. They never expire, so the app
// can store them (e.g. in posterPhotos) and load them with AsyncImage; GET /files/... redirects to a
// short-lived download URL. The key contains a random ID, and the signature stops anyone from guessing others.

import { createHmac, timingSafeEqual } from "node:crypto";
import type { Config } from "../config.js";

function signature(config: Config, key: string): string {
  return createHmac("sha256", config.JWT_SECRET).update(`file\n${key}`).digest("hex").slice(0, 32);
}

export function fileUrl(config: Config, key: string): string {
  return `${config.PUBLIC_BASE_URL}/files/${encodeURI(key)}?sig=${signature(config, key)}`;
}

export function verifyFileSignature(config: Config, key: string, sig: string | undefined): boolean {
  if (!sig) return false;
  const expected = Buffer.from(signature(config, key));
  const given = Buffer.from(sig);
  return expected.length === given.length && timingSafeEqual(expected, given);
}

// Turns a URL from fileUrl() back into its blob key, or null if it is not one of ours.
export function blobKeyFromFileUrl(config: Config, url: string): string | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  const marker = "/files/";
  const at = parsed.pathname.indexOf(marker);
  if (at === -1) return null;
  const key = decodeURI(parsed.pathname.slice(at + marker.length));
  return verifyFileSignature(config, key, parsed.searchParams.get("sig") ?? undefined) ? key : null;
}
