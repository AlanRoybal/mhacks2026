// Escrow risk: the credit-risk toolkit a lender uses, applied to small jobs paid through escrow.
//
//   1. Trust score   Each worker's chance of finishing a job well is a Beta posterior over their history.
//                    Outcomes are star-weighted, older jobs decay (half-life 120 days), bigger jobs count
//                    more, and the k-th job with the same poster counts 1/k, so a pair of accounts trading
//                    5-star jobs can't farm a reputation. We act on the posterior's lower bound (5th
//                    percentile), not its mean, so two lucky jobs don't look like fifty good ones.
//   2. Expected loss EL = PD x LGD x EAD per escrow (the Basel formula). PD combines the worker failing and
//                    the poster disputing in bad faith; LGD depends on the rail: a refunded card charge
//                    loses its processing fee, and a card payout can be charged back after release, while
//                    a USDC release can't be reversed.
//   3. Exposure      Like a credit limit: how much escrow a worker may hold at once grows with the size and
//                    quality of their record, so a brand-new account can't be handed a $400 job.
//   4. Reserve       Monte Carlo over every open escrow gives the platform's loss distribution: expected
//                    loss, 95%/99% Value at Risk and 99% Expected Shortfall, the cash to hold in reserve.
//
// Everything here is pure; services/risk.ts gathers the inputs from the store.

export interface Outcome {
  at: string;
  // The poster (for a worker's history), so repeated counterparties can be discounted.
  counterpartyId: string;
  amountCents: number;
  result: "completed" | "failed" | "withdrew";
  // The poster's rating of a completed job, if they left one.
  stars?: number;
}

export interface TrustScore {
  // Posterior mean chance of a good outcome, and its conservative 5th percentile.
  mean: number;
  lower: number;
  // Probability of default: 1 - lower.
  pd: number;
  // How much history the score rests on, after decay and counterparty discounting.
  effectiveJobs: number;
  alpha: number;
  beta: number;
}

// Prior: like 5 past jobs at an 80% success rate, so a new worker starts plausible but unproven.
export const TRUST_PRIOR = { alpha: 4, beta: 1 };
const HALF_LIFE_DAYS = 120;
const Z_95 = 1.645;
const DAY_MS = 24 * 3600_000;

const clamp = (n: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, n));

// How good an outcome was, from 0 to 1. A 5-star job is a full success; 3 stars is half.
export function outcomeValue(o: Outcome): number {
  if (o.result === "failed") return 0;
  if (o.result === "withdrew") return 0.2;
  return o.stars === undefined ? 0.9 : clamp((o.stars - 1) / 4, 0, 1);
}

export function trustScore(history: Outcome[], now: Date): TrustScore {
  let alpha = TRUST_PRIOR.alpha;
  let beta = TRUST_PRIOR.beta;
  let effectiveJobs = 0;
  const seen = new Map<string, number>();
  for (const o of [...history].sort((a, b) => a.at.localeCompare(b.at))) {
    const ageDays = Math.max(0, (now.getTime() - Date.parse(o.at)) / DAY_MS);
    const decay = 0.5 ** (ageDays / HALF_LIFE_DAYS);
    const k = (seen.get(o.counterpartyId) ?? 0) + 1;
    seen.set(o.counterpartyId, k);
    // $20 is a typical job; a $5 errand counts half, a $80 one twice.
    const size = clamp(Math.sqrt(o.amountCents / 2000), 0.5, 2);
    const weight = decay * size / k;
    const value = outcomeValue(o);
    alpha += weight * value;
    beta += weight * (1 - value);
    effectiveJobs += weight;
  }
  const n = alpha + beta;
  const mean = alpha / n;
  const sd = Math.sqrt((alpha * beta) / (n * n * (n + 1)));
  const lower = clamp(mean - Z_95 * sd, 0, 1);
  return { mean, lower, pd: 1 - lower, effectiveJobs, alpha, beta };
}

// Bad-faith disputes: disputes the poster opened that ended in the worker's favor. Beta(0.5, 19.5)
// prior: about 2.5% of posters, before we know anything about this one.
export function disputeProbability(disputesLost: number, jobsPosted: number): number {
  const alpha = 0.5 + disputesLost;
  const beta = 19.5 + Math.max(0, jobsPosted - disputesLost);
  return alpha / (alpha + beta);
}

export type RiskRail = "card" | "usdc";

// Card processing (Stripe US): 2.9% + 30c, which a refund doesn't give back. Chargebacks cost $15 on
// top of the reversed amount. Roughly half of bad-faith disputes become a chargeback once paid out.
const CARD_FEE_RATE = 0.029;
const CARD_FEE_FIXED = 30;
const CHARGEBACK_FEE = 1500;
const CHARGEBACK_GIVEN_DISPUTE = 0.5;
const USDC_GAS = 5;

export interface LossEvent {
  label: string;
  probability: number;
  lossCents: number;
}

export interface ExpectedLoss {
  // EAD: the escrowed amount at stake.
  exposureCents: number;
  // PD: chance this escrow ends in some loss.
  pd: number;
  // LGD: share of the exposure lost when it does.
  lgd: number;
  // EL = PD x LGD x EAD.
  expectedLossCents: number;
  events: LossEvent[];
  tier: RiskTier;
}

export type RiskTier = "A" | "B" | "C" | "D" | "E";

export function riskTier(expectedLossCents: number, exposureCents: number): RiskTier {
  const rate = exposureCents > 0 ? expectedLossCents / exposureCents : 0;
  if (rate < 0.005) return "A";
  if (rate < 0.015) return "B";
  if (rate < 0.03) return "C";
  if (rate < 0.06) return "D";
  return "E";
}

export function expectedLoss(input: { amountCents: number; rail: RiskRail; workerPd: number; posterDispute: number }): ExpectedLoss {
  const amount = input.amountCents;
  const fail = clamp(input.workerPd, 0, 1);
  // A failed job is refunded from escrow, so the poster is whole; the platform keeps the processing cost.
  const refundCost = input.rail === "card" ? Math.round(amount * CARD_FEE_RATE + CARD_FEE_FIXED) : USDC_GAS;
  const events: LossEvent[] = [{ label: "Refund after a failed job", probability: fail, lossCents: refundCost }];
  if (input.rail === "card") {
    // Paid out, then charged back: the platform has already paid the worker.
    const chargeback = (1 - fail) * clamp(input.posterDispute, 0, 1) * CHARGEBACK_GIVEN_DISPUTE;
    events.push({ label: "Chargeback after payout", probability: chargeback, lossCents: amount + CHARGEBACK_FEE });
  }
  const pd = Math.min(1, events.reduce((sum, e) => sum + e.probability, 0));
  const el = events.reduce((sum, e) => sum + e.probability * e.lossCents, 0);
  const lgd = pd > 0 && amount > 0 ? el / (pd * amount) : 0;
  return { exposureCents: amount, pd, lgd, expectedLossCents: Math.round(el), events, tier: riskTier(el, amount) };
}

// Credit-limit style: $50 to start, growing with history and with the conservative trust score.
export const MIN_EXPOSURE_CENTS = 5_000;
export const MAX_EXPOSURE_CENTS = 100_000;
export function exposureLimitCents(trust: TrustScore): number {
  const earned = 4_000 * (1 + trust.effectiveJobs) * trust.lower ** 2;
  return Math.round(clamp(earned, MIN_EXPOSURE_CENTS, MAX_EXPOSURE_CENTS) / 100) * 100;
}

// Seeded PRNG (mulberry32) so a report is reproducible.
function mulberry32(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export interface PortfolioRisk {
  runs: number;
  expectedLossCents: number;
  var95Cents: number;
  var99Cents: number;
  // Expected Shortfall: the average loss in the worst 1% of outcomes. The reserve to hold.
  es99Cents: number;
  worstCents: number;
}

// Each escrow's loss events are mutually exclusive (a job either fails, gets charged back, or neither).
export function simulatePortfolio(escrows: LossEvent[][], runs = 20_000, seed = 42): PortfolioRisk {
  const random = mulberry32(seed);
  const losses = new Float64Array(runs);
  for (let r = 0; r < runs; r++) {
    let total = 0;
    for (const events of escrows) {
      let u = random();
      for (const e of events) {
        if (u < e.probability) {
          total += e.lossCents;
          break;
        }
        u -= e.probability;
      }
    }
    losses[r] = total;
  }
  losses.sort();
  const at = (q: number) => losses[Math.min(runs - 1, Math.floor(q * runs))] ?? 0;
  const tailStart = Math.floor(0.99 * runs);
  let tail = 0;
  for (let i = tailStart; i < runs; i++) tail += losses[i] ?? 0;
  const mean = losses.reduce((s, x) => s + x, 0) / runs;
  return {
    runs,
    expectedLossCents: Math.round(mean),
    var95Cents: Math.round(at(0.95)),
    var99Cents: Math.round(at(0.99)),
    es99Cents: Math.round(tail / Math.max(1, runs - tailStart)),
    worstCents: Math.round(losses[runs - 1] ?? 0),
  };
}
