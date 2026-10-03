import assert from "node:assert/strict";
import { test } from "node:test";
import type { Job, Offer } from "../domain/types.js";
import { apsPayload, OFFER_CATEGORY } from "./push.js";
import { renderPush } from "./templates.js";

const job = { jobId: "j1", title: "Sketch a logo", bountyCents: 1500, totalCents: 1650, estMinutes: 10, remote: false } as Job;
const offer = { offerId: "o1", estMinutes: 10, distanceKm: 0.64, why: "Graphic design (LinkedIn)", expiresAt: "2026-10-04T15:00:30.000Z" } as Offer;

test("offer pushes use the app's actionable category and carry the IDs it routes on", () => {
  const message = renderPush("offer", job, offer);
  assert.equal(message.title, "$15 · 10 min · 0.4 mi");
  const payload = apsPayload(message) as { aps: Record<string, unknown>; jobId: string; offerId: string };
  assert.equal(payload.aps.category, OFFER_CATEGORY);
  assert.equal(payload.aps["interruption-level"], "time-sensitive");
  assert.equal(payload.jobId, "j1");
  assert.equal(payload.offerId, "o1");
});

test("other pushes are plain alerts", () => {
  const payload = apsPayload(renderPush("paid", job, null)) as { aps: Record<string, unknown>; type: string };
  assert.equal(payload.aps.category, undefined);
  assert.equal(payload.aps["interruption-level"], "active");
  assert.equal(payload.type, "paid");
});
