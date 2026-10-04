import assert from "node:assert/strict";
import { test } from "node:test";
import { applyEvent, getJobOrThrow } from "../services/jobs.js";
import { apiClient, isoIn } from "../testing/api.js";
import { testDeps } from "../testing/harness.js";

const SITE = { lat: 42.2808, lng: -83.743 };
const SYSTEM = { kind: "system" as const, source: "test" };

async function fundedLogoJob() {
  const deps = testDeps();
  const api = apiClient(deps);
  const poster = await api.login("poster");
  const designer = await api.readyWorker("designer", { skill: "Logo design", ...SITE });
  const illustrator = await api.readyWorker("illustrator", { skill: "Illustration and logo sketching", lat: 42.29, lng: -83.74 });
  const farAway = await api.readyWorker("faraway", { skill: "Logo design", lat: 42.33, lng: -83.04 });
  const picky = await api.readyWorker("picky", { skill: "Logo design", ...SITE, prefs: { minPay: 50 } });
  const notReady = await api.login("noskills");

  const { body: job } = await api.call("POST", "/jobs", poster.token, {
    title: "Sketch a logo for a coffee shop",
    description: "Paper sketch of a logo for Bean There",
    category: "DESIGN",
    location: { latitude: SITE.lat, longitude: SITE.lng, address: "State St" },
    deadline: isoIn(deps, 6),
    payAmount: 15,
  });
  await applyEvent(deps, job.id, { type: "FUND_CONFIRMED", amountCents: 1650 }, SYSTEM);
  await deps.settle();
  return { deps, api, poster, designer, illustrator, farAway, picky, notReady, jobId: job.id as string };
}

test("a funded job is offered to one eligible worker at a time, with a reason", async () => {
  const { deps, api, designer, illustrator, farAway, picky, notReady, poster, jobId } = await fundedLogoJob();
  const job = await getJobOrThrow(deps, jobId);
  assert.equal(job.state, "OFFERED");
  const offeredTo = job.currentOffer?.workerId;
  assert.ok(offeredTo === designer.userId || offeredTo === illustrator.userId);

  const offers = await deps.store.listOffersForJob(jobId);
  const candidates = new Set(offers.map((o) => o.workerId));
  for (const excluded of [farAway, picky, notReady, poster]) assert.ok(!candidates.has(excluded.userId));

  const push = deps.push.sent.find((p) => p.message.type === "offer");
  assert.equal(push?.userId, offeredTo);
  assert.equal(push?.message.category, "BOUNTY_JOB_OFFER");
  assert.equal(push?.message.offerId, job.currentOffer?.offerId);

  const token = offeredTo === designer.userId ? designer.token : illustrator.token;
  const current = await api.call("GET", "/offers/current", token);
  assert.equal(current.body.offer.id, job.currentOffer?.offerId);
  assert.equal(current.body.job.status, "OFFERED");
  assert.ok(current.body.job.matchReason);
  assert.deepEqual(current.body.job.allowedActions, ["accept", "decline"]);
});

test("decline moves to the next worker; accept assigns the job once", async () => {
  const { deps, api, designer, illustrator, jobId } = await fundedLogoJob();
  const first = (await getJobOrThrow(deps, jobId)).currentOffer;
  assert.ok(first);
  const [firstWorker, secondWorker] = first.workerId === designer.userId ? [designer, illustrator] : [illustrator, designer];

  const declined = await api.call("POST", `/offers/${first.offerId}/decline`, firstWorker.token);
  assert.equal(declined.body.offer.status, "declined");
  await deps.settle();

  const second = (await getJobOrThrow(deps, jobId)).currentOffer;
  assert.equal(second?.workerId, secondWorker.userId);

  const accepted = await api.call("POST", `/offers/${second?.offerId}/accept`, secondWorker.token);
  assert.equal(accepted.status, 200);
  assert.equal(accepted.body.job.status, "ACCEPTED");
  assert.equal(accepted.body.job.worker.id, secondWorker.userId);

  const again = await api.call("POST", `/offers/${second?.offerId}/accept`, secondWorker.token);
  assert.equal(again.status, 200, "a second tap by the winner is not an error");
  const late = await api.call("POST", `/offers/${first.offerId}/accept`, firstWorker.token);
  assert.equal(late.body.error.code, "offer_not_current");

  await deps.settle();
  const working = await api.call("GET", "/jobs/working", secondWorker.token);
  assert.equal((working.body as unknown as { id: string }[])[0]?.id, jobId);
});

test("when every candidate passes, the poster hears once and matching retries later", async () => {
  const { deps, api, designer, illustrator, jobId } = await fundedLogoJob();
  for (let i = 0; i < 2; i++) {
    const offer = (await getJobOrThrow(deps, jobId)).currentOffer;
    assert.ok(offer);
    const token = offer.workerId === designer.userId ? designer.token : illustrator.token;
    await api.call("POST", `/offers/${offer.offerId}/decline`, token);
    await deps.settle();
  }
  const job = await getJobOrThrow(deps, jobId);
  assert.equal(job.state, "FUNDED");
  assert.equal(deps.push.sent.filter((p) => p.message.type === "no_match_yet").length, 1);
  assert.ok([...deps.scheduler.pending.values()].some((t) => t.timer === "rematch"));
});

test("GET /offers/:id (opened from the push) shows the job while the offer is live", async () => {
  const { deps, api, designer, illustrator, jobId } = await fundedLogoJob();
  const live = (await getJobOrThrow(deps, jobId)).currentOffer;
  assert.ok(live);
  const holder = live.workerId === designer.userId ? designer : illustrator;
  const fromPush = await api.call("GET", `/offers/${live.offerId}`, holder.token);
  assert.equal(fromPush.body.offer.status, "sent");
  assert.equal(fromPush.body.job.id, jobId);
  await api.call("POST", `/offers/${live.offerId}/decline`, holder.token);
  await deps.settle();
  const after = await api.call("GET", `/offers/${live.offerId}`, holder.token);
  assert.equal(after.body.offer.status, "declined");
  assert.equal(after.body.job, null);
});

test("every push lands on the notifications page until it is read", async () => {
  const { deps, api, designer, illustrator, jobId } = await fundedLogoJob();
  const offer = (await getJobOrThrow(deps, jobId)).currentOffer;
  const worker = offer?.workerId === designer.userId ? designer : illustrator;

  const inbox = await api.call("GET", "/me/notifications", worker.token);
  assert.equal(inbox.body.unreadCount, 1);
  assert.equal(inbox.body.items[0].type, "offer");
  assert.equal(inbox.body.items[0].jobId, jobId);
  assert.equal(inbox.body.items[0].offerId, offer?.offerId);
  assert.equal(inbox.body.items[0].read, false);

  assert.equal((await api.call("POST", "/me/notifications/read", worker.token)).body.unreadCount, 0);
  const after = await api.call("GET", "/me/notifications", worker.token);
  assert.equal(after.body.unreadCount, 0);
  assert.equal(after.body.items[0].read, true);

  const nobody = await api.login("quiet");
  assert.deepEqual((await api.call("GET", "/me/notifications", nobody.token)).body, { items: [], unreadCount: 0 });
});
