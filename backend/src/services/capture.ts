// Proof that a photo or video came from the Bounty app's own camera, without marking the work itself.
//
// START issues the job a random capture key (job.capture.key), sent only to the assigned worker's app.
// Right after each capture the app signs the file's SHA-256, the capture time and the GPS fix with that
// key (HMAC-SHA256). On submission the server hashes the uploaded bytes and checks the signature, so a
// camera-roll photo, an edited file, or a capture from another job can't pass as in-app proof.
//
// The signed message is plain text, so the Swift side (Bounty/Features/Work/ProofCapture.swift) can build
// exactly the same bytes: whole seconds for the time, and coordinates with five decimals.

import { createHash, createHmac, timingSafeEqual } from "node:crypto";

export interface CaptureClaim {
  jobId: string;
  sha256: string;
  capturedAt: string;
  lat?: number;
  lng?: number;
}

export const sha256Hex = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex");

export function captureMessage(claim: CaptureClaim): string {
  const seconds = Math.floor(Date.parse(claim.capturedAt) / 1000);
  const coordinate = (n: number | undefined) => (n === undefined ? "" : n.toFixed(5));
  return ["bounty-capture-v1", claim.jobId, claim.sha256.toLowerCase(), String(seconds), coordinate(claim.lat), coordinate(claim.lng)].join("\n");
}

export function signCapture(key: string, claim: CaptureClaim): string {
  return createHmac("sha256", Buffer.from(key, "base64url")).update(captureMessage(claim)).digest("base64");
}

export function verifyCapture(key: string, claim: CaptureClaim, signature: string): boolean {
  const expected = Buffer.from(signCapture(key, claim));
  const given = Buffer.from(signature);
  return expected.length === given.length && timingSafeEqual(expected, given);
}
