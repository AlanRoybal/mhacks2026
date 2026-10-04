// Stripe Connect "separate charges and transfers": the poster pays the platform (PaymentIntent),
// the platform holds it, then transfers the bounty to the worker's Express account or refunds the poster.
// Every call carries an idempotency key, and payouts also check the job's transfer_group first because
// Stripe only remembers idempotency keys for about 24 hours.

import Stripe from "stripe";
import type { Job, User } from "../domain/types.js";
import type { FundingSession, PaymentRail } from "./rail.js";

export interface StripeConfig {
  secretKey: string;
  publishableKey: string;
  webhookSecret?: string;
}

export class StripeRail implements PaymentRail {
  readonly stripe: Stripe;

  constructor(private readonly cfg: StripeConfig) {
    this.stripe = new Stripe(cfg.secretKey, { maxNetworkRetries: 2 });
  }

  async startFunding(job: Job, poster: User): Promise<FundingSession> {
    let intent: Stripe.PaymentIntent | null = null;
    if (job.payment.paymentIntentId) {
      intent = await this.stripe.paymentIntents.retrieve(job.payment.paymentIntentId);
      // A canceled intent or one for a different amount cannot be reused.
      if (intent.status === "canceled" || intent.amount !== job.totalCents) intent = null;
    }
    intent ??= await this.stripe.paymentIntents.create(
      {
        amount: job.totalCents,
        currency: "usd",
        automatic_payment_methods: { enabled: true },
        transfer_group: job.jobId,
        description: job.title.slice(0, 200),
        metadata: { jobId: job.jobId, posterId: poster.userId },
      },
      { idempotencyKey: `fund:${job.jobId}:${job.totalCents}` },
    );
    return {
      provider: "stripe",
      paymentIntentId: intent.id,
      paymentIntentClientSecret: intent.client_secret ?? "",
      customerId: null,
      ephemeralKeySecret: null,
      publishableKey: this.cfg.publishableKey,
    };
  }

  async payout(job: Job, worker: User, attempt = 0) {
    const destination = worker.payouts.stripeAccountId;
    if (!destination) throw new Error(`Worker ${worker.userId} has no Stripe account`);
    const existing = await this.stripe.transfers.list({ transfer_group: job.jobId, limit: 10 });
    const previous = existing.data.find((t) => t.destination === destination || (typeof t.destination === "object" && t.destination?.id === destination));
    if (previous) return { transferId: previous.id };
    const transfer = await this.stripe.transfers.create(
      {
        amount: job.bountyCents,
        currency: "usd",
        destination,
        transfer_group: job.jobId,
        // Lets the transfer go out before the charge settles (needed for a 2-minute demo).
        ...(job.payment.chargeId ? { source_transaction: job.payment.chargeId } : {}),
        metadata: { jobId: job.jobId },
      },
      // Stripe replays a keyed request's saved result (errors too) for 24 h, so each attempt after a
      // rejection gets its own key. The transfer_group lookup above still prevents paying twice.
      { idempotencyKey: attempt > 0 ? `payout:${job.jobId}:${attempt}` : `payout:${job.jobId}` },
    );
    return { transferId: transfer.id };
  }

  async refund(job: Job) {
    if (!job.payment.paymentIntentId) return { refundId: "none" };
    const refund = await this.stripe.refunds.create(
      { payment_intent: job.payment.paymentIntentId, metadata: { jobId: job.jobId } },
      { idempotencyKey: `refund:${job.jobId}` },
    );
    return { refundId: refund.id };
  }

  // Refunds a payment that arrived for a job that can no longer take it (double checkout, canceled draft).
  async refundOrphan(paymentIntentId: string) {
    await this.stripe.refunds.create({ payment_intent: paymentIntentId, metadata: { reason: "orphan_payment" } }, { idempotencyKey: `orphan:${paymentIntentId}` });
  }

  verifyWebhook(rawBody: string, signature: string): Stripe.Event {
    if (!this.cfg.webhookSecret) throw new Error("STRIPE_WEBHOOK_SECRET is not set");
    return this.stripe.webhooks.constructEvent(rawBody, signature, this.cfg.webhookSecret);
  }

  // Newer Stripe platforms can't create Accounts v1 connected accounts with the legacy `type` field, and a
  // platform that doesn't take on losses can't use Express or recipient-only accounts. So each worker gets
  // a full-dashboard account (Standard in v1 terms) through Accounts v2, with Stripe collecting fees and
  // covering losses. Payouts are /v1/transfers into the account, which on v2 accounts needs the recipient
  // configuration's stripe_balance.stripe_transfers capability (the v1 view's `transfers: active` is not
  // enough). The recipient configuration needs a contact email, so accounts without one stay merchant-only
  // until the worker adds an email.
  async createConnectAccount(user: User): Promise<string> {
    const account = await this.stripe.v2.core.accounts.create(
      {
        ...(user.email ? { contact_email: user.email } : {}),
        display_name: user.displayName,
        identity: { country: "us", entity_type: "individual" },
        configuration: {
          merchant: { capabilities: { card_payments: { requested: true } } },
          ...(user.email ? { recipient: { capabilities: { stripe_balance: { stripe_transfers: { requested: true } } } } } : {}),
        },
        defaults: { responsibilities: { fees_collector: "stripe", losses_collector: "stripe" } },
        dashboard: "full",
        metadata: { userId: user.userId },
      },
      { idempotencyKey: `account-v2:${user.userId}` },
    );
    return account.id;
  }

  async onboardingLink(accountId: string, refreshUrl: string, returnUrl: string): Promise<string> {
    const link = await this.stripe.v2.core.accountLinks.create({
      account: accountId,
      use_case: { type: "account_onboarding", account_onboarding: { refresh_url: refreshUrl, return_url: returnUrl } },
    });
    return link.url;
  }

  // Accounts created before the recipient configuration was requested get it added (idempotent). Returns
  // false when it can't be added yet (no contact email on the account).
  async ensureRecipient(accountId: string): Promise<boolean> {
    const account = await this.stripe.v2.core.accounts.retrieve(accountId, { include: ["configuration.recipient"] });
    if (account.configuration?.recipient?.capabilities?.stripe_balance?.stripe_transfers) return true;
    if (!account.contact_email) return false;
    await this.stripe.v2.core.accounts.update(accountId, {
      configuration: { recipient: { capabilities: { stripe_balance: { stripe_transfers: { requested: true } } } } },
    });
    return true;
  }

  // True once Stripe will accept transfers into the account: the recipient stripe_transfers capability is active.
  async transfersEnabled(accountId: string): Promise<boolean> {
    const account = await this.stripe.v2.core.accounts.retrieve(accountId, { include: ["configuration.recipient"] });
    return account.configuration?.recipient?.capabilities?.stripe_balance?.stripe_transfers?.status === "active";
  }
}
