import assert from "node:assert/strict";
import { test } from "node:test";
import { disputeProbability, expectedLoss, exposureLimitCents, simulatePortfolio, trustScore, type Outcome } from "./risk.js";

const NOW = new Date("2026-10-04T15:00:00Z");
const daysAgo = (d: number) => new Date(NOW.getTime() - d * 86_400_000).toISOString();
const job = (counterpartyId: string, result: Outcome["result"], stars?: number, age = 1, amountCents = 2000): Outcome => ({
  at: daysAgo(age),
  counterpartyId,
  amountCents,
  result,
  stars,
});

test("a new worker starts plausible but unproven, and the $50 floor applies", () => {
  const fresh = trustScore([], NOW);
  assert.equal(fresh.mean, 0.8);
  assert.ok(fresh.lower < 0.6, "the conservative bound is well below the mean with no history");
  assert.equal(exposureLimitCents(fresh), 5_000);
});

test("ten good jobs for different posters earn trust and a bigger exposure limit", () => {
  const good = Array.from({ length: 10 }, (_, i) => job(`poster-${i}`, "completed", 5));
  const trust = trustScore(good, NOW);
  assert.ok(trust.mean > 0.9 && trust.lower > 0.8);
  assert.ok(exposureLimitCents(trust) >= 25_000, `limit ${exposureLimitCents(trust)}`);
});

test("a rating ring can't farm trust: the k-th job with the same poster counts 1/k", () => {
  const ring = Array.from({ length: 10 }, () => job("sock-puppet", "completed", 5));
  const honest = Array.from({ length: 10 }, (_, i) => job(`poster-${i}`, "completed", 5));
  const farmed = trustScore(ring, NOW);
  assert.ok(farmed.effectiveJobs < 3, `10 jobs with one poster count as ${farmed.effectiveJobs.toFixed(2)}`);
  assert.ok(exposureLimitCents(farmed) < exposureLimitCents(trustScore(honest, NOW)) / 2);
});

test("failures and low stars cut trust; old history fades", () => {
  const mixed = [...Array.from({ length: 5 }, (_, i) => job(`p${i}`, "completed", 5)), job("x", "failed"), job("y", "completed", 1)];
  assert.ok(trustScore(mixed, NOW).mean < trustScore(mixed.slice(0, 5), NOW).mean);
  const stale = trustScore([job("a", "failed", undefined, 720)], NOW);
  const recent = trustScore([job("a", "failed", undefined, 1)], NOW);
  assert.ok(stale.mean > recent.mean, "a two-year-old failure weighs far less than yesterday's");
});

test("EL = PD x LGD x EAD, and the rail changes the loss: USDC can't be charged back", () => {
  const card = expectedLoss({ amountCents: 10_000, rail: "card", workerPd: 0.1, posterDispute: 0.2 });
  // Refund: 10% x $3.20 fee; chargeback: 90% x 20% x 50% x ($100 + $15).
  assert.equal(card.expectedLossCents, Math.round(0.1 * 320 + 0.09 * 11_500));
  assert.ok(Math.abs(card.pd * card.lgd * card.exposureCents - card.expectedLossCents) < 1);
  const usdc = expectedLoss({ amountCents: 10_000, rail: "usdc", workerPd: 0.1, posterDispute: 0.2 });
  assert.equal(usdc.events.length, 1);
  assert.ok(usdc.expectedLossCents < card.expectedLossCents / 100);
  assert.equal(usdc.tier, "A");
});

test("bad-faith disputes raise a poster's dispute probability", () => {
  assert.equal(disputeProbability(0, 0), 0.025);
  assert.ok(disputeProbability(3, 5) > 5 * disputeProbability(0, 5), "three lost disputes in five jobs is a strong signal");
});

test("the Monte Carlo reserve is reproducible and ordered EL <= VaR99 <= ES99", () => {
  const escrows = Array.from({ length: 50 }, () => expectedLoss({ amountCents: 4_000, rail: "card", workerPd: 0.15, posterDispute: 0.05 }).events);
  const a = simulatePortfolio(escrows, 5_000, 7);
  assert.deepEqual(simulatePortfolio(escrows, 5_000, 7), a, "same seed, same answer");
  const analytic = escrows.reduce((sum, events) => sum + events.reduce((s, e) => s + e.probability * e.lossCents, 0), 0);
  assert.ok(Math.abs(a.expectedLossCents - analytic) / analytic < 0.1, `simulated ${a.expectedLossCents} vs analytic ${Math.round(analytic)}`);
  assert.ok(a.expectedLossCents <= a.var95Cents && a.var95Cents <= a.var99Cents && a.var99Cents <= a.es99Cents && a.es99Cents <= a.worstCents);
});
