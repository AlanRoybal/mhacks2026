// The routes iosA's TwinKit package calls, exercised with the JSON its Swift encoders produce.

import { strToU8, zipSync } from "fflate";
import assert from "node:assert/strict";
import { test } from "node:test";
import { applyEvent, getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn, type Json } from "../testing/api.js";
import { testDeps } from "../testing/harness.js";

const SITE = { lat: 42.2808, lng: -83.743 };

test("profile: read, edit the skill list, import a LinkedIn export, sync availability", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const { token } = await api.login("worker");

  const empty = await api.call("GET", "/profile/twin", token);
  assert.deepEqual(Object.keys(empty.body).sort(), ["certifications", "education", "headline", "roles", "skills", "updated_at", "user_id"]);
  assert.equal(empty.body.headline, null);
  assert.match(empty.body.updated_at, /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/);

  const edited = await api.call("PUT", "/profile/twin/skills", token, {
    skills: [{ id: "tmp", name: "Logo design", confidence: 0.9, source: "user", years_of_experience: null }],
  });
  assert.deepEqual(edited.body.skills, [{ id: "logo design", name: "Logo design", confidence: 0.9, source: "user", years_of_experience: null }]);

  // Upload a LinkedIn export the way ProfileIngestionService does.
  const target = await api.call("POST", "/profile/upload-url", token, {
    file_name: "Basic_LinkedInDataExport.zip",
    content_type: "application/zip",
    byte_count: 512,
    source: "linkedin_export",
  });
  assert.deepEqual(Object.keys(target.body).sort(), ["headers", "object_key", "upload_url"]);
  const zip = zipSync({ "Skills.csv": strToU8("Name\nIllustration\nLogo design\n") });
  const put = await api.app.request(target.body.upload_url.replace(deps.config.PUBLIC_BASE_URL, ""), { method: "PUT", headers: target.body.headers, body: zip });
  assert.equal(put.status, 200);
  const ingest = await api.call("POST", "/profile/ingest", token, { object_key: target.body.object_key, source: "linkedin_export" });
  assert.equal(ingest.body.status, "processing");
  assert.ok(ingest.body.ingestion_id);
  await deps.settle();

  const imported = await api.call("GET", "/profile/twin", token);
  const byName = new Map((imported.body.skills as Json[]).map((s) => [s.name, s]));
  assert.equal(byName.get("Illustration")?.source, "linkedin");
  assert.ok(byName.has("Logo design"));

  // Removing a skill from the list deletes it, and it stays deleted.
  const trimmed = await api.call("PUT", "/profile/twin/skills", token, { skills: [{ id: "illustration", name: "Illustration", confidence: 0.6, source: "linkedin" }] });
  assert.deepEqual(
    (trimmed.body.skills as Json[]).map((s) => s.name),
    ["Illustration"],
  );

  const sync = await api.app.request("/profile/availability", {
    method: "PUT",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({
      generated_at: "2026-10-04T15:00:00Z",
      window_start: "2026-10-04T15:00:00Z",
      window_end: "2026-10-18T15:00:00Z",
      busy_blocks: [{ start: "2026-10-04T18:00:00Z", end: "2026-10-04T19:00:00Z" }],
    }),
  });
  assert.equal(sync.status, 204);
  const twin = await api.call("GET", "/twin", token);
  assert.equal(twin.body.availability.busy.length, 1);
});

test("offers: respond with a decision; the loser gets TwinKit's error envelope", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const first = await api.readyWorker("first", { skill: "Logo design", ...SITE });
  const second = await api.readyWorker("second", { skill: "Logo design", ...SITE });
  const { body: job } = await api.call("POST", "/jobs", poster.token, {
    title: "Sketch a logo for a coffee shop",
    description: "Paper sketch",
    category: "DESIGN",
    location: null,
    deadline: isoIn(deps, 6),
    payAmount: 15,
  });
  await applyEvent(deps, job.id, { type: "FUND_CONFIRMED", amountCents: 1650 }, { kind: "system", source: "test" });
  await deps.settle();

  const offer = (await getJobOrThrow(deps, job.id)).currentOffer;
  assert.ok(offer);
  const [winner, other] = offer.workerId === first.userId ? [first, second] : [second, first];
  const accepted = await api.call("POST", `/offers/${offer.offerId}/respond`, winner.token, { decision: "accept" });
  assert.deepEqual(accepted.body, { offer_id: offer.offerId, job_id: job.id, status: "ACCEPTED" });

  const late = await api.call("POST", `/offers/${offer.offerId}/respond`, other.token, { decision: "accept" });
  assert.equal(late.status, 404, "an offer that isn't yours is not found");
  assert.deepEqual(Object.keys(late.body.error).sort(), ["code", "message"]);
});
