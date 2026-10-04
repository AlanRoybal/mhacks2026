import assert from "node:assert/strict";
import { test } from "node:test";
import type { ChecklistItem } from "./types.js";
import { verificationPlan } from "./verification.js";

const LIMITS = { checkInRadiusM: 200, photoRadiusM: 400, confidence: 0.7 };
const item = (id: string, evidenceType: ChecklistItem["evidenceType"], extra: Partial<ChecklistItem> = {}): ChecklistItem => ({
  id,
  text: id,
  evidenceType,
  required: true,
  ...extra,
});

test("lawn mowing is verified on site: location to start, check-in, located photos, before and after", () => {
  const plan = verificationPlan(
    {
      remote: false,
      address: "1200 S University Ave",
      checklist: [item("c1", "PHOTO", { photoCount: 2, beforeAfter: true }), item("c2", "PHOTO"), item("c3", "CHECK_IN")],
    },
    LIMITS,
  );
  assert.deepEqual(
    plan.signals.map((s) => s.id),
    ["on_site_start", "time_on_site", "on_site_check_in", "photo_location", "fresh_photos", "before_after", "deadline", "ai_review"],
  );
  const start = plan.signals.find((s) => s.id === "on_site_start");
  assert.equal(start?.enforcement, "blocks");
  assert.match(start?.detail ?? "", /within 200 m of 1200 S University Ave/);
  assert.equal(plan.signals.find((s) => s.id === "photo_location")?.enforcement, "poster_reviews");
  assert.match(plan.signals.find((s) => s.id === "ai_review")?.detail ?? "", /3 required items .* 70% confident/);
  assert.match(plan.privacy, /only while a job is open/);
});

test("a remote design job records no location and is judged on the deliverable", () => {
  const plan = verificationPlan({ remote: true, checklist: [item("c1", "FILE"), item("c2", "LINK", { required: false })] }, LIMITS);
  assert.deepEqual(
    plan.signals.map((s) => s.id),
    ["deliverable", "deadline", "ai_review"],
  );
  assert.ok(plan.signals.every((s) => !/GPS|location/i.test(s.collects ?? "")));
  assert.match(plan.privacy, /no location at all/);
  assert.match(plan.summary, /from the deliverable/);
});
