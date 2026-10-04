// The verification plan travels with every job, so the poster sees it before paying and the worker before accepting.

import assert from "node:assert/strict";
import { test } from "node:test";
import { applyEvent, getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn, type Json } from "../testing/api.js";
import { testDeps } from "../testing/harness.js";

const SITE = { lat: 42.2808, lng: -83.743 };

test("poster and offered worker both see what will be checked", async () => {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const worker = await api.readyWorker("mower", { skill: "Lawn mowing", ...SITE });
  const { body: draft } = await api.call("POST", "/jobs", poster.token, {
    title: "Mow my front lawn",
    description: "Front yard only, bag the clippings",
    category: "YARD_WORK",
    location: { latitude: SITE.lat, longitude: SITE.lng, address: "1200 S University Ave" },
    deadline: isoIn(deps, 6),
    payAmount: 40,
  });
  const ids = (draft.verification.signals as Json[]).map((s) => s.id);
  assert.ok(ids.includes("on_site_start"), "visible on the draft, before funding");
  assert.ok(ids.includes("photo_location"));

  await applyEvent(deps, draft.id, { type: "FUND_CONFIRMED", amountCents: 4400 }, { kind: "system", source: "test" });
  await deps.settle();
  const offer = (await getJobOrThrow(deps, draft.id)).currentOffer;
  assert.equal(offer?.workerId, worker.userId);
  const { body: offered } = await api.call("GET", `/jobs/${draft.id}`, worker.token);
  assert.equal(offered.myRole, "offered");
  assert.deepEqual(offered.verification, draft.verification, "the worker sees the same plan before accepting");
  assert.match(offered.verification.signals[0].detail, /within 200 m of 1200 S University Ave/);
});
