// Local dev and seed data: money "moves" instantly and nothing is charged.
import type { Job } from "../domain/types.js";
import type { FundingSession, PaymentRail } from "./rail.js";

export class FakeRail implements PaymentRail {
  async startFunding(job: Job): Promise<FundingSession> {
    return {
      provider: "fake",
      paymentIntentId: null,
      paymentIntentClientSecret: `fake_secret_${job.jobId}`,
      customerId: null,
      ephemeralKeySecret: null,
      publishableKey: "pk_fake",
    };
  }

  async payout(job: Job) {
    return { transferId: `fake_tr_${job.jobId}` };
  }

  async refund(job: Job) {
    return { refundId: `fake_re_${job.jobId}` };
  }
}
