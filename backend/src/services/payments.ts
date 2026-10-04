// Funding, payouts, refunds and Stripe webhooks. Money only moves from the payout/refund effects,
// which the state machine emits; this file just carries them out idempotently.

import type Stripe from "stripe";
import type { Deps } from "../deps.js";
import { TransitionError } from "../domain/jobMachine.js";
import type { Job, User } from "../domain/types.js";
import { AppError, conflict, forbidden } from "../lib/errors.js";
import { RailUnavailableError, type FundingSession } from "../payments/index.js";
import { VersionConflictError } from "../store/index.js";
import { applyEvent, getJobOrThrow } from "./jobs.js";
import { hasRequiredEvidence } from "./postings.js";
import { updateUser } from "./users.js";

const SYSTEM = (source: string) => ({ kind: "system" as const, source });

// US-16: start checkout for a draft. With the fake rail, funding is confirmed immediately.
export async function startFunding(deps: Deps, user: User, jobId: string): Promise<{ session: FundingSession; job: Job }> {
  const job = await getJobOrThrow(deps, jobId);
  if (job.posterId !== user.userId) throw forbidden("Only the poster can fund this job");
  if (job.state !== "DRAFT") throw conflict("already_funded", `The job is already ${job.state}`);
  if (!hasRequiredEvidence(job.checklist)) throw conflict("checklist_incomplete", "Add at least one required photo, link or file item before funding");
  let session: FundingSession;
  try {
    session = await deps.payments.railFor(job).startFunding(job, user);
  } catch (e) {
    if (e instanceof RailUnavailableError) throw new AppError(501, "rail_unavailable", "USDC funding isn't available yet. Use USD.");
    throw e;
  }

  if (session.provider === "fake") {
    const funded = await applyEvent(deps, jobId, { type: "FUND_CONFIRMED", amountCents: job.totalCents }, SYSTEM("fake-payments"));
    return { session, job: funded };
  }

  // Remember the PaymentIntent: it locks the price and checklist and lets the webhook match the payment.
  if (session.paymentIntentId && session.paymentIntentId !== job.payment.paymentIntentId) {
    const next = { ...job, payment: { ...job.payment, paymentIntentId: session.paymentIntentId }, version: job.version + 1, updatedAt: deps.now().toISOString() };
    try {
      await deps.store.saveJob(job.version, next);
      return { session, job: next };
    } catch (e) {
      if (e instanceof VersionConflictError) throw conflict("busy", "The job changed during checkout; try again");
      throw e;
    }
  }
  return { session, job };
}

// The "payout" effect.
export async function runPayout(deps: Deps, jobId: string): Promise<void> {
  const job = await deps.store.getJob(jobId);
  if (!job || job.state !== "RELEASED" || job.payment.transferId || !job.workerId) return;
  const worker = await deps.store.getUser(job.workerId);
  if (!worker) throw new Error(`Worker ${job.workerId} not found for payout`);
  const { transferId } = await deps.payments.railFor(job).payout(job, worker);
  await applyEvent(deps, jobId, { type: "PAYOUT_CONFIRMED", transferId }, SYSTEM("payments"));
  deps.log.info("Payout sent", { jobId, transferId, amountCents: job.bountyCents });
}

// The "refund" effect.
export async function runRefund(deps: Deps, jobId: string): Promise<void> {
  const job = await deps.store.getJob(jobId);
  if (!job || job.state !== "REFUNDED" || job.payment.refundId) return;
  const { refundId } = await deps.payments.railFor(job).refund(job);
  await applyEvent(deps, jobId, { type: "REFUND_CONFIRMED", refundId }, SYSTEM("payments"));
  deps.log.info("Refund sent", { jobId, refundId, amountCents: job.totalCents });
}

// Asks Stripe directly whether a draft's payment went through and records it, so funding is
// confirmed even when no webhook reaches this server (local dev without `stripe listen`).
export async function syncFundingFromStripe(deps: Deps, job: Job): Promise<Job> {
  const stripe = deps.payments.stripe;
  if (job.state !== "DRAFT" || job.rail !== "stripe" || !job.payment.paymentIntentId || !stripe) return job;
  const intent = await stripe.stripe.paymentIntents.retrieve(job.payment.paymentIntentId);
  if (intent.status === "succeeded") await onPaymentSucceeded(deps, intent);
  return getJobOrThrow(deps, job.jobId);
}

async function onPaymentSucceeded(deps: Deps, intent: Stripe.PaymentIntent): Promise<void> {
  const jobId = intent.metadata?.jobId;
  if (!jobId) return;
  const job = await deps.store.getJob(jobId);
  // Duplicate delivery of a payment we already recorded.
  if (job && job.state !== "DRAFT" && job.payment.paymentIntentId === intent.id) return;
  const chargeId = typeof intent.latest_charge === "string" ? intent.latest_charge : intent.latest_charge?.id;
  try {
    if (!job) throw new TransitionError("invalid_transition", "Job no longer exists");
    await applyEvent(deps, jobId, { type: "FUND_CONFIRMED", amountCents: intent.amount_received, paymentIntentId: intent.id, chargeId }, SYSTEM("stripe"));
  } catch (e) {
    if (!(e instanceof TransitionError) && !(e instanceof AppError)) throw e;
    // A concurrent delivery of this same payment may have funded the job a moment ago.
    const latest = await deps.store.getJob(jobId);
    if (latest && latest.state !== "DRAFT" && latest.payment.paymentIntentId === intent.id) return;
    // Money arrived for a job that can't take it (deleted draft, second checkout, wrong amount): give it back.
    deps.log.warn("Refunding a payment the job could not accept", { jobId, paymentIntentId: intent.id, reason: e.message });
    await deps.payments.stripe?.refundOrphan(intent.id);
  }
}

async function onAccountUpdated(deps: Deps, account: Stripe.Account): Promise<void> {
  const userId = await deps.store.kvGet<string>(`stripe-account:${account.id}`);
  if (!userId) return;
  const enabled = account.capabilities?.transfers === "active";
  await updateUser(deps, userId, (u) => {
    u.payouts.stripeTransfersEnabled = enabled;
  });
}

export async function handleStripeWebhook(deps: Deps, rawBody: string, signature: string): Promise<void> {
  const stripe = deps.payments.stripe;
  if (!stripe) throw new AppError(501, "not_configured", "Stripe is not configured");
  let event: Stripe.Event;
  try {
    event = stripe.verifyWebhook(rawBody, signature);
  } catch {
    throw new AppError(400, "bad_signature", "Invalid Stripe signature");
  }
  if (await deps.store.kvGet(`stripe-event:${event.id}`)) return;
  if (event.type === "payment_intent.succeeded") await onPaymentSucceeded(deps, event.data.object as Stripe.PaymentIntent);
  if (event.type === "account.updated") await onAccountUpdated(deps, event.data.object as Stripe.Account);
  // Recorded only after handling, so a failure is retried by Stripe.
  await deps.store.kvPut(`stripe-event:${event.id}`, event.type, { ttlSeconds: 7 * 24 * 3600 });
}

// US-52: Stripe Connect Express onboarding. Returns a URL to open in SFSafariViewController.
export async function connectOnboardingUrl(deps: Deps, user: User, refreshUrl: string): Promise<string> {
  const stripe = deps.payments.stripe;
  if (!stripe) throw new AppError(501, "not_configured", "Stripe is not configured; payouts are simulated locally");
  let accountId = user.payouts.stripeAccountId;
  if (!accountId) {
    const created = await stripe.createConnectAccount(user);
    accountId = created;
    await deps.store.kvPut(`stripe-account:${created}`, user.userId);
    await updateUser(deps, user.userId, (u) => {
      u.payouts.stripeAccountId = created;
    });
  }
  return stripe.onboardingLink(accountId, refreshUrl, `${deps.config.PUBLIC_BASE_URL}/wallet/connect/return`);
}

// Pulls the account status from Stripe (useful when webhooks aren't forwarded to a laptop).
export async function syncPayoutStatus(deps: Deps, user: User): Promise<User> {
  const stripe = deps.payments.stripe;
  const accountId = user.payouts.stripeAccountId;
  if (!stripe || !accountId) return user;
  const enabled = await stripe.transfersEnabled(accountId);
  return updateUser(deps, user.userId, (u) => {
    u.payouts.stripeTransfersEnabled = enabled;
  });
}

const PENDING_STATES = new Set(["ACCEPTED", "IN_PROGRESS", "SUBMITTED", "IN_REVIEW", "DISPUTED"]);

// US-53/54/55: pending (in escrow), releasing, and paid earnings per currency, plus history.
export async function earnings(deps: Deps, user: User) {
  const jobs = await deps.store.listJobsByWorker(user.userId);
  const totals = new Map<string, { currency: string; pending: number; releasing: number; paid: number }>();
  const items = [];
  for (const job of jobs) {
    const status = PENDING_STATES.has(job.state)
      ? "pending"
      : job.state === "RELEASED"
        ? job.payment.transferId
          ? "paid"
          : "releasing"
        : job.state === "REFUNDED"
          ? "refunded"
          : null;
    if (!status) continue;
    const total = totals.get(job.currency) ?? { currency: job.currency, pending: 0, releasing: 0, paid: 0 };
    if (status !== "refunded") total[status] += job.bountyCents / 100;
    totals.set(job.currency, total);
    items.push({
      jobId: job.jobId,
      title: job.title,
      amount: job.bountyCents / 100,
      currency: job.currency,
      status,
      jobStatus: job.state,
      rail: job.rail,
      reference: job.payment.transferId ?? null,
      updatedAt: job.updatedAt.replace(/\.\d{3}Z$/, "Z"),
    });
  }
  const usd = totals.get("USD") ?? { currency: "USD", pending: 0, releasing: 0, paid: 0 };
  return {
    available: usd.paid,
    pending: usd.pending + usd.releasing,
    currencies: [...totals.values()],
    payouts: { stripeConnected: Boolean(user.payouts.stripeAccountId), payoutsEnabled: user.payouts.stripeTransfersEnabled },
    items,
  };
}
