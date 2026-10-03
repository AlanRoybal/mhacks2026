import assert from "node:assert/strict";
import { test } from "node:test";
import { FakeAi } from "../ai/fake.js";
import type { ChecklistDraft } from "../ai/index.js";
import type { Job, Proof } from "../domain/types.js";
import { testDeps } from "../testing/harness.js";
import { decide } from "./grading.js";
import { createDraft, setChecklist } from "./postings.js";
import { newUser } from "./users.js";

function aiReturning(draft: ChecklistDraft) {
  return Object.assign(new FakeAi(), { generateChecklist: async () => draft });
}

const input = (deps: ReturnType<typeof testDeps>) => ({
  title: "Mow front lawn",
  description: "Small yard",
  category: "YARD_WORK" as const,
  location: { lat: 42.28, lng: -83.74 },
  deadline: new Date(deps.now().getTime() + 6 * 3600_000).toISOString(),
  bountyCents: 3500,
  currency: "USD" as const,
  photos: [],
});

test("an empty AI checklist falls back to the category template", async () => {
  const deps = testDeps();
  deps.ai = aiReturning({ items: [], estMinutes: 30, flags: [] });
  const poster = newUser({ displayName: "P" }, deps.now());
  await deps.store.createUser(poster);
  const job = await createDraft(deps, poster, input(deps));
  assert.ok(job.checklist.some((i) => i.required && i.evidenceType === "PHOTO"));
  assert.ok(job.checklist.some((i) => i.evidenceType === "CHECK_IN"));
});

test("an all-optional AI checklist gets its first evidence item marked required", async () => {
  const deps = testDeps();
  deps.ai = aiReturning({
    items: [{ text: "Lawn photo", evidenceType: "PHOTO", photoCount: 1, beforeAfter: false, required: false, angleHint: "" }],
    estMinutes: 30,
    flags: [],
  });
  const poster = newUser({ displayName: "P" }, deps.now());
  await deps.store.createUser(poster);
  const job = await createDraft(deps, poster, input(deps));
  assert.equal(job.checklist.find((i) => i.evidenceType === "PHOTO")?.required, true);

  await assert.rejects(
    setChecklist(deps, poster, job.jobId, [{ text: "Checked in", evidenceType: "CHECK_IN", required: true }, { text: "Photo", evidenceType: "PHOTO", required: false }]),
    /required/,
  );
});

test("grading never passes on a check-in alone when no evidence item is marked required", () => {
  const job = {
    checklist: [
      { id: "c1", text: "photo", evidenceType: "PHOTO", photoCount: 1, required: false },
      { id: "c2", text: "check-in", evidenceType: "CHECK_IN", required: true },
    ],
  } as Job;
  const proof = { items: [], checks: { outsideGeofence: [] } } as unknown as Proof;
  const verdicts = [
    { itemId: "c1", verdict: "fail" as const, confidence: 0.99, reason: "" },
    { itemId: "c2", verdict: "pass" as const, confidence: 1, reason: "" },
  ];
  assert.equal(decide(job, proof, verdicts, true).decision, "fail");
});
