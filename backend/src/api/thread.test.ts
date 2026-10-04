import assert from "node:assert/strict";
import { test } from "node:test";
import { applyEvent, getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn } from "../testing/api.js";
import { testDeps, type TestDeps } from "../testing/harness.js";

const SECRET = "messenger-secret-for-tests-0123456789";
const POSTER_PHONE = "+17345550100";
const SYSTEM = { kind: "system" as const, source: "test" };

const lastCode = (deps: TestDeps) => /code is (\d{6})/.exec(deps.messenger.sent.at(-1)?.text ?? "")?.[1] ?? "";

async function linkPhone(deps: TestDeps, api: ReturnType<typeof apiClient>, token: string, number = "(734) 555-0100") {
  const sent = await api.call("POST", "/me/phone", token, { number });
  assert.equal(sent.status, 200);
  return api.call("POST", "/me/phone/verify", token, { code: lastCode(deps) });
}

async function inbound(api: ReturnType<typeof apiClient>, from: string, text: string, messageId: string, secret = SECRET) {
  const res = await api.app.request("/internal/imessage", {
    method: "POST",
    headers: { "content-type": "application/json", "x-messenger-secret": secret },
    body: JSON.stringify({ from, text, messageId }),
  });
  return res.status;
}

// A poster with a linked phone and a worker who has accepted their remote logo job.
async function acceptedJob(opts: { posterTexts?: boolean } = {}) {
  const deps = testDeps({ MESSENGER_SECRET: SECRET });
  const api = apiClient(deps);
  const poster = await api.login("poster");
  await api.call("PATCH", "/me", poster.token, { displayName: "Jamie Rivera" });
  if (opts.posterTexts !== false) assert.equal((await linkPhone(deps, api, poster.token)).status, 200);
  const worker = await api.readyWorker("designer", { skill: "Logo design", lat: 42.28, lng: -83.74 });
  await api.call("PATCH", "/me", worker.token, { displayName: "Alan Roybal" });
  const { body: job } = await api.call("POST", "/jobs", poster.token, {
    title: "Sketch a logo for a coffee shop",
    description: "Paper sketch of a logo for Bean There",
    category: "DESIGN",
    deadline: isoIn(deps, 6),
    payAmount: 15,
  });
  await applyEvent(deps, job.id, { type: "FUND_CONFIRMED", amountCents: 1650 }, SYSTEM);
  await deps.settle();
  const offer = (await getJobOrThrow(deps, job.id)).currentOffer;
  assert.equal(offer?.workerId, worker.userId);
  deps.messenger.sent.length = 0;
  assert.equal((await api.call("POST", `/offers/${offer.offerId}/accept`, worker.token)).status, 200);
  await deps.settle();
  return { deps, api, poster, worker, jobId: job.id as string };
}

test("a phone is linked only after the texted code is entered", async () => {
  const deps = testDeps({ MESSENGER_SECRET: SECRET });
  const api = apiClient(deps);
  const user = await api.login("someone");

  assert.equal((await api.call("POST", "/me/phone", user.token, { number: "555-0100" })).body.error.code, "invalid_phone");
  await api.call("POST", "/me/phone", user.token, { number: "734-555-0100" });
  assert.equal(deps.messenger.sent[0]?.to, POSTER_PHONE);
  assert.equal((await api.call("POST", "/me/phone", user.token, { number: "734-555-0100" })).body.error.code, "code_recently_sent");

  const wrong = lastCode(deps) === "000000" ? "111111" : "000000";
  assert.equal((await api.call("POST", "/me/phone/verify", user.token, { code: wrong })).body.error.code, "code_mismatch");
  const verified = await api.call("POST", "/me/phone/verify", user.token, { code: lastCode(deps) });
  assert.deepEqual(verified.body.phone, { number: POSTER_PHONE, jobTexts: true });
  assert.equal(await deps.store.kvGet(`phone:${POSTER_PHONE}`), user.userId);

  const off = await api.call("PATCH", "/me/phone", user.token, { jobTexts: false });
  assert.equal(off.body.phone.jobTexts, false);
  assert.equal((await api.call("DELETE", "/me/phone", user.token)).body.phone, null);
});

test("the worker's twin texts the poster when the job is accepted and when it starts", async () => {
  const { deps, api, worker, jobId } = await acceptedJob();
  const opener = deps.messenger.sent.find((m) => m.to === POSTER_PHONE);
  assert.match(opener?.text ?? "", /Alan's Bounty twin/);

  await api.call("POST", `/jobs/${jobId}/start`, worker.token);
  await deps.settle();
  assert.match(deps.messenger.sent.at(-1)?.text ?? "", /Alan just checked in/);

  const thread = await api.call("GET", `/jobs/${jobId}/thread`, worker.token);
  assert.equal(thread.body.available, true);
  assert.equal(thread.body.active, true);
  assert.deepEqual(thread.body.messages.map((m: { from: string }) => m.from), ["twin", "twin"]);
});

test("poster texts become details or questions for the worker, and the worker's answer is relayed", async () => {
  const { deps, api, worker, poster, jobId } = await acceptedJob();

  assert.equal(await inbound(api, POSTER_PHONE, "The side door code is 4417", "m1"), 202);
  await deps.settle();
  assert.match(deps.messenger.sent.at(-1)?.text ?? "", /passed that on to Alan/);
  // A repeat delivery of the same message is ignored.
  const sentBefore = deps.messenger.sent.length;
  await inbound(api, POSTER_PHONE, "The side door code is 4417", "m1");
  await deps.settle();
  assert.equal(deps.messenger.sent.length, sentBefore);

  await inbound(api, POSTER_PHONE, "When will you arrive?", "m2");
  await deps.settle();
  const asWorker = await api.call("GET", `/jobs/${jobId}/thread`, worker.token);
  assert.deepEqual(asWorker.body.details, ["The side door code is 4417"]);
  assert.equal(asWorker.body.pendingQuestion, "When will you arrive?");
  const inbox = await api.call("GET", "/me/notifications", worker.token);
  assert.equal(inbox.body.items[0].type, "thread_message");

  const replied = await api.call("POST", `/jobs/${jobId}/thread`, worker.token, { text: "Around 3 PM" });
  assert.equal(replied.status, 200);
  assert.equal(replied.body.pendingQuestion, null);
  assert.deepEqual(deps.messenger.sent.at(-1), { to: POSTER_PHONE, text: "Alan says: Around 3 PM" });

  // The poster sees the whole thread too, but never the worker's pending question.
  const asPoster = await api.call("GET", `/jobs/${jobId}/thread`, poster.token);
  assert.equal(asPoster.body.messages.at(-1).from, "worker");
  assert.equal(asPoster.body.pendingQuestion, null);
});

test("texts from unknown numbers, bad secrets and unreachable posters are handled", async () => {
  const { deps, api } = await acceptedJob();
  assert.equal(await inbound(api, "+15550000000", "hi", "x1", "wrong-secret-wrong-secret-wrong"), 401);
  await inbound(api, "+15550000000", "hi", "x2");
  await deps.settle();
  assert.match(deps.messenger.sent.at(-1)?.text ?? "", /isn't linked to a Bounty account/);

  const quiet = await acceptedJob({ posterTexts: false });
  assert.equal(quiet.deps.messenger.sent.length, 0);
  const res = await quiet.api.call("POST", `/jobs/${quiet.jobId}/thread`, quiet.worker.token, { text: "Hello" });
  assert.equal(res.body.error.code, "poster_unreachable");
  assert.equal((await quiet.api.call("GET", `/jobs/${quiet.jobId}/thread`, quiet.worker.token)).body.available, false);
});
