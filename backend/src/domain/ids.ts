import { randomBytes, randomInt } from "node:crypto";

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

// No 0/O, 1/I/L, 2/Z, 5/S, 8/B: the code is read off handwritten paper by a vision model.
const CODE_ALPHABET = "ACDEFHJKMNPRTUVWXY3479";

// One-time code shown to the worker and required in proof photos, e.g. "K7Q-4MX".
export function challengeCode(): string {
  let code = "";
  for (let i = 0; i < 6; i++) code += CODE_ALPHABET[randomInt(CODE_ALPHABET.length)];
  return `${code.slice(0, 3)}-${code.slice(3)}`;
}
