// "Follow the money": a job's payment steps (charged → held in escrow → released → paid, or refunded),
// read from its append-only ledger, each with the payment reference that proves it. Also the time from
// the release decision to the payout landing ("time to paid").

import type { Deps } from "../deps.js";
import type { LedgerEvent } from "../domain/events.js";
import { formatUsd } from "../domain/money.js";
import type { Job } from "../domain/types.js";

export type MoneyStepKind = "charged" | "held" | "released" | "paid" | "refund_decided" | "refunded";

export interface MoneyStep {
  kind: MoneyStepKind;
  label: string;
  detail: string;
  at: string;
  // Dollars moved at this step, when it moved money.
  amount: number | null;
  // Stripe object ID, chain transaction hash, or test-rail ID.
  reference: string | null;
  referenceUrl: string | null;
}

const whyReleased: Partial<Record<LedgerEvent["type"], string>> = {
  APPROVE: "The poster approved the work",
  REVIEW_WINDOW_EXPIRED: "The review window ended, so payment released automatically",
  RESOLVE: "The dispute was resolved for the worker",
  DISPUTE_TIMEOUT: "The dispute window ended",
};

/** Where to check a reference: Basescan for chain hashes, the Stripe dashboard for Stripe IDs. */
export function referenceUrl(deps: Deps, reference: string | null | undefined): string | null {
  if (!reference) return null;
  if (/^0x[0-9a-fA-F]{64}$/.test(reference)) return `https://sepolia.basescan.org/tx/${reference}`;
  if (/^(pi|ch|tr|re|py|po)_[A-Za-z0-9]+$/.test(reference)) {
    const live = deps.config.STRIPE_SECRET_KEY?.startsWith("sk_live") ?? false;
    return `https://dashboard.stripe.com/${live ? "" : "test/"}search?query=${encodeURIComponent(reference)}`;
  }
  return null;
}

const wire = (iso: string) => iso.replace(/\.\d{3}Z$/, "Z");

/** The release decision and payout times, and the seconds between them. */
export function payoutTiming(ledger: LedgerEvent[]) {
  const released = ledger.find((e) => e.to === "RELEASED" && e.from !== "RELEASED");
  const paid = ledger.find((e) => e.type === "PAYOUT_CONFIRMED");
  const seconds = released && paid ? Math.max(0, Math.round((Date.parse(paid.at) - Date.parse(released.at)) / 1000)) : null;
  return { releasedAt: released?.at ?? null, paidAt: paid?.at ?? null, timeToPaidSeconds: seconds };
}

export function moneyTrail(deps: Deps, job: Job, ledger: LedgerEvent[], viewer: { isPoster: boolean }) {
  const bounty = job.bountyCents / 100;
  const steps: MoneyStep[] = [];
  const step = (s: Omit<MoneyStep, "referenceUrl" | "at"> & { at: string }) => steps.push({ ...s, at: wire(s.at), referenceUrl: referenceUrl(deps, s.reference) });

  for (const e of ledger) {
    const ev = e.event;
    if (ev?.type === "FUND_CONFIRMED") {
      const reference = ev.paymentIntentId ?? ev.chargeId ?? job.payment.paymentIntentId ?? null;
      step({
        kind: "charged",
        label: viewer.isPoster ? `Charged ${formatUsd(job.totalCents)}` : `${formatUsd(job.bountyCents)} paid in by the poster`,
        detail: viewer.isPoster && job.feeCents > 0 ? `${formatUsd(job.bountyCents)} job pay + ${formatUsd(job.feeCents)} Bounty fee` : "Card payment confirmed by Stripe",
        at: e.at,
        amount: viewer.isPoster ? job.totalCents / 100 : bounty,
        reference,
      });
      step({ kind: "held", label: "Held in escrow", detail: "Nobody can spend it until the work is verified, or it's refunded", at: e.at, amount: null, reference: null });
    } else if (e.to === "RELEASED" && e.from !== "RELEASED") {
      step({ kind: "released", label: "Released from escrow", detail: whyReleased[e.type] ?? "Payment released", at: e.at, amount: null, reference: null });
    } else if (ev?.type === "PAYOUT_CONFIRMED") {
      step({ kind: "paid", label: `${formatUsd(job.bountyCents)} paid ${viewer.isPoster ? "to the worker" : "to you"}`, detail: "Transferred to the worker's payout account", at: e.at, amount: bounty, reference: ev.transferId });
    } else if (e.to === "REFUNDED" && e.from !== "REFUNDED") {
      step({ kind: "refund_decided", label: "Refund approved", detail: refundReason(e.type), at: e.at, amount: null, reference: null });
    } else if (ev?.type === "REFUND_CONFIRMED") {
      step({ kind: "refunded", label: `${formatUsd(job.totalCents)} refunded to the poster`, detail: "Returned to the card that paid", at: e.at, amount: job.totalCents / 100, reference: ev.refundId === "none" ? null : ev.refundId });
    }
  }
  const timing = payoutTiming(ledger);
  return {
    rail: job.rail,
    currency: job.currency,
    steps,
    releasedAt: timing.releasedAt ? wire(timing.releasedAt) : null,
    paidAt: timing.paidAt ? wire(timing.paidAt) : null,
    timeToPaidSeconds: timing.timeToPaidSeconds,
  };
}

function refundReason(type: LedgerEvent["type"]): string {
  switch (type) {
    case "CANCEL": return "The poster canceled before anyone accepted";
    case "REJECT": return "The poster rejected work that failed review";
    case "DEADLINE_PASSED": return "The deadline passed before the work was done";
    case "RESOLVE": return "The dispute was resolved for the poster";
    case "DISPUTE_TIMEOUT": return "The dispute window ended";
    default: return "The job ended without payment to a worker";
  }
}
