import type { PushTemplate } from "../domain/events.js";
import { formatUsd } from "../domain/money.js";
import type { Job, Offer } from "../domain/types.js";
import { OFFER_CATEGORY, type PushMessage } from "./push.js";

const KM_PER_MILE = 1.609344;

function distanceLabel(job: Job, offer: Offer | null): string {
  if (job.remote) return "Remote";
  if (offer?.distanceKm === undefined) return "Nearby";
  return `${(offer.distanceKm / KM_PER_MILE).toFixed(1)} mi`;
}

export function renderPush(template: PushTemplate, job: Job, offer: Offer | null): PushMessage {
  const base = { type: template, jobId: job.jobId };
  const t = `"${job.title}"`;
  switch (template) {
    case "offer": {
      const minutes = offer?.estMinutes ?? job.estMinutes;
      return {
        ...base,
        offerId: offer?.offerId,
        title: `${formatUsd(job.bountyCents)} · ${minutes} min · ${distanceLabel(job, offer)}`,
        body: offer?.why ? `${job.title}: ${offer.why}` : `New match: ${job.title}`,
        category: OFFER_CATEGORY,
        timeSensitive: true,
        expiresAt: offer?.expiresAt,
      };
    }
    case "offer_accepted":
      return { ...base, title: "Your job was accepted", body: `A worker accepted ${t}.` };
    case "job_canceled":
      return { ...base, title: "Job canceled", body: `The poster canceled ${t}.` };
    case "worker_withdrew":
      return { ...base, title: "Worker withdrew", body: `We're finding someone else for ${t}.` };
    case "no_match_yet":
      return { ...base, title: "Still looking", body: `No one has accepted ${t} yet. We'll keep trying, or you can widen the radius or extend the deadline.` };
    case "proof_ready":
      return { ...base, title: "Proof ready for review", body: `${t} passed AI review. Payment releases automatically if you don't respond.` };
    case "proof_needs_decision":
      return { ...base, title: "Your decision is needed", body: `The AI couldn't confirm ${t}. Review the proof to approve or dispute.` };
    case "proof_passed":
      return { ...base, title: "Proof passed", body: `${t} passed. The poster has a review window, then you get paid.` };
    case "proof_failed":
      return { ...base, title: "Proof needs another try", body: `Some checklist items for ${t} didn't pass. Open the job to see why and retry.` };
    case "proof_escalated":
      return { ...base, title: "Proof sent to the poster", body: `The poster will review ${t} directly.` };
    case "disputed":
      return { ...base, title: "Job under review", body: `${t} is waiting for an admin decision.` };
    case "resolved":
      return { ...base, title: "Dispute resolved", body: `The dispute on ${t} was resolved. Open the job for details.` };
    case "deadline_missed":
      return { ...base, title: "Deadline passed", body: `${t} wasn't finished before its deadline. The poster has been refunded.` };
    case "unmatched_refund":
      return { ...base, title: "No worker found", body: `No one accepted ${t} before the deadline. You've been refunded.` };
    case "paid":
      return { ...base, title: `You were paid ${formatUsd(job.bountyCents)}`, body: `For ${t}.` };
    case "refunded":
      return { ...base, title: "Refund issued", body: `${formatUsd(job.totalCents)} for ${t} is on its way back to you.` };
  }
}
