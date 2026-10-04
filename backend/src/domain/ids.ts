import { randomBytes } from "node:crypto";

const CROCKFORD = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

// 26-character, time-sortable, URL-safe ID (ULID layout: 10 time chars + 16 random chars).
export function newId(now = Date.now()): string {
  let time = "";
  let t = now;
  for (let i = 0; i < 10; i++) {
    time = CROCKFORD[t % 32] + time;
    t = Math.floor(t / 32);
  }
  const bytes = randomBytes(16);
  let rand = "";
  for (const b of bytes) rand += CROCKFORD[b % 32];
  return time + rand;
}

// Per-job secret, issued when the worker starts. The app signs every photo and video it captures with
// it (services/capture.ts), which is how the server knows proof came from the Bounty camera.
export function captureKey(): string {
  return randomBytes(32).toString("base64url");
}
