import assert from "node:assert/strict";
import { test } from "node:test";
import { getJobOrThrow } from "../services/jobs.js";
import { newUser } from "../services/users.js";
import { apiClient, isoIn } from "../testing/api.js";
import { testDeps } from "../testing/harness.js";
import { signSession } from "./auth.js";

test("demo tools: fund without Stripe, force an offer, explain matching, fast-forward", async () => {
  const deps = testDeps({ DEMO_MODE: "true" });
  const api = apiClient(deps);
  const poster = await api.login("seed-poster-1");
  const judge = await api.readyWorker("judge", { skill: "Logo design", lat: 42.28, lng: -83.74 });
  const { body: draft } = await api.call("POST", "/jobs", poster.token, {
    title: "Sketch a logo for a coffee shop",
    description: "Paper sketch",
    category: "DESIGN",
    location: null,
    deadline: isoIn(deps, 3),
    payAmount: 15,
  });

  const funded = await api.call("POST", `/demo/jobs/${draft.id}/fund`, poster.token);
  assert.equal(funded.body.status, "FUNDED");
  await deps.settle();
  // Matching already offered it to the only ready worker; let that offer lapse first.
  const offered = await getJobOrThrow(deps, draft.id);
  assert.equal(offered.currentOffer?.workerId, judge.userId);
  await api.call("POST", `/offers/${offered.currentOffer?.offerId}/decline`, judge.token);
  await deps.settle();

  const explain = await api.call("GET", `/demo/jobs/${draft.id}/explain`, poster.token);
  assert.equal(explain.body.users.find((u: { userId: string }) => u.userId === judge.userId).reason, "already declined or withdrew");

  const other = await api.readyWorker("judge2", { skill: "Logo design", lat: 42.28, lng: -83.74 });
  const forced = await api.call("POST", "/demo/offer", poster.token, { jobId: draft.id, handle: "judge2" });
  assert.equal(forced.status, 200, JSON.stringify(forced.body));
  const current = await api.call("GET", "/offers/current", other.token);
  assert.equal(current.body.offer.id, forced.body.offerId);

  const ff = await api.call("POST", `/demo/jobs/${draft.id}/fast-forward`, poster.token);
  assert.equal(ff.body.fired, "offer_expire");
});

test("demo routes are absent outside demo mode", async () => {
  const deps = testDeps({ STAGE: "prod", JWT_SECRET: "x".repeat(40) });
  const api = apiClient(deps);
  const user = newUser({ displayName: "Someone" }, deps.now());
  await deps.store.createUser(user);
  const res = await api.call("POST", "/demo/offer", await signSession(deps, user.userId), {});
  assert.equal(res.status, 404);
});
