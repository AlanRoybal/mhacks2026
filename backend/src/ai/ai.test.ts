import assert from "node:assert/strict";
import { test } from "node:test";
import { silentLogger } from "../lib/log.js";
import type { JobBrief } from "./ai.js";
import { ClaudeAi, type MessagesClient } from "./claude.js";
import { cosine, HashEmbedder } from "./embed.js";
import { templateChecklist } from "./fake.js";
import { ResilientAi } from "./resilient.js";

const job: JobBrief = { title: "Sketch a logo for a coffee shop", description: "Pencil sketch on paper", category: "DESIGN", remote: false, bountyCents: 1500 };

function stubClient(response: object): MessagesClient {
  return { beta: { messages: { parse: async () => response } } } as unknown as MessagesClient;
}

const refusal = { stop_reason: "refusal", parsed_output: null, usage: { input_tokens: 1, output_tokens: 1 } };

test("a refused checklist falls back to the category template", async () => {
  const ai = new ResilientAi(new ClaudeAi(stubClient(refusal), "claude-opus-5-5", silentLogger, true), silentLogger);
  const draft = await ai.generateChecklist(job);
  assert.ok(draft.items.length >= 2);
  assert.ok(draft.items.some((i) => i.evidenceType === "CHECK_IN"), "in-person jobs get a check-in item");
});

test("a failed grade sends every item to the poster as unclear", async () => {
  const ai = new ResilientAi(new ClaudeAi(stubClient(refusal), "claude-opus-5-5", silentLogger, true), silentLogger);
  const grade = await ai.grade({
    job,
    checklist: [{ id: "c1", text: "Logo visible", evidenceType: "PHOTO", photoCount: 1, required: true }],
    challengeCode: "ACD-EFH",
    evidence: [],
  });
  assert.deepEqual(
    grade.items.map((i) => i.verdict),
    ["unclear"],
  );
});

test("profile extraction has no fallback, so the import can be retried", async () => {
  const ai = new ResilientAi(new ClaudeAi(stubClient(refusal), "claude-opus-5-5", silentLogger, true), silentLogger);
  await assert.rejects(ai.extractProfile({ kind: "resume_pdf", pdf: Buffer.from("%PDF") }));
});

test("structured output passes through", async () => {
  const parsed = { items: [{ text: "Logo visible", evidenceType: "PHOTO", photoCount: 1, beforeAfter: false, required: true, angleHint: "" }], estMinutes: 12, flags: [] };
  const ai = new ClaudeAi(stubClient({ stop_reason: "end_turn", parsed_output: parsed, usage: { input_tokens: 1, output_tokens: 1 } }), "m", silentLogger, false);
  assert.deepEqual(await ai.generateChecklist(job), parsed);
});

test("remote templates drop location and before/after items", () => {
  const draft = templateChecklist({ ...job, category: "YARD_WORK", remote: true });
  assert.ok(!draft.items.some((i) => i.evidenceType === "CHECK_IN" || i.beforeAfter));
});

test("hash embeddings put related skills closer together", async () => {
  const e = new HashEmbedder();
  const jobVec = await e.embed("Sketch a logo design for a coffee shop");
  const designer = await e.embed("Skills: logo design, illustration, branding");
  const mower = await e.embed("Skills: lawn mowing, yard work, snow shoveling");
  assert.ok(cosine(jobVec, designer) > cosine(jobVec, mower));
});
