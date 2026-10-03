import type { Config } from "../config.js";
import type { Job } from "../domain/types.js";
import { FakeRail } from "./fakeRail.js";
import { RailUnavailableError, type FundingSession, type PaymentRail } from "./rail.js";
import { StripeRail } from "./stripeRail.js";

export interface Payments {
  stripe?: StripeRail;
  railFor(job: Pick<Job, "rail">): PaymentRail;
}

// USDC escrow on Base Sepolia belongs to the payments workstream; until it lands, USDC jobs can't be funded.
const usdcRail: PaymentRail = {
  startFunding: async () => {
    throw new RailUnavailableError("USDC");
  },
  payout: async () => {
    throw new RailUnavailableError("USDC");
  },
  refund: async () => {
    throw new RailUnavailableError("USDC");
  },
};

export function createPayments(config: Config): Payments {
  const fake = new FakeRail();
  let stripe: StripeRail | undefined;
  if (config.STRIPE_SECRET_KEY) {
    stripe = new StripeRail({ secretKey: config.STRIPE_SECRET_KEY, publishableKey: config.STRIPE_PUBLISHABLE_KEY ?? "", webhookSecret: config.STRIPE_WEBHOOK_SECRET });
  } else if (config.PAYMENTS_PROVIDER === "stripe") {
    throw new Error("PAYMENTS_PROVIDER=stripe needs STRIPE_SECRET_KEY and STRIPE_PUBLISHABLE_KEY");
  }
  return {
    stripe,
    railFor(job) {
      if (job.rail === "fake") return fake;
      if (job.rail === "usdc") return usdcRail;
      if (!stripe) throw new Error("This job uses Stripe but STRIPE_SECRET_KEY is not set");
      return stripe;
    },
  };
}

export { RailUnavailableError, type FundingSession, type PaymentRail };
