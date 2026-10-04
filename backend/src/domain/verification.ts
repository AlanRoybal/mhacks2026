// The verification plan: before any money moves, what Bounty will check to decide whether the work
// was done, and what it records about the worker to do so. It is worked out from the job itself (in
// person or remote, and the checklist the AI drafted and the poster edited), so both sides see the
// same rules the server enforces:
//
//   on_site_start     jobMachine START: the worker must be within checkInRadiusM to start
//   on_site_check_in  grading: CHECK_IN items are judged from GPS by the server, not the model
//   photo_location    proof checks: photos taken outside photoRadiusM keep the job from auto-paying
//   fresh_photos      proof checks: signed Bounty-camera captures after Start, none reused from another job
//   before_after      grading: the model checks the before and after show the same place
//   deliverable       grading: files and links are judged against the description
//   deadline          jobMachine SUBMIT: no proof after the deadline
//   ai_review         grading: every required item needs confidence >= 0.7, else the poster decides
//
// Location is only ever read at those moments; nothing tracks the worker in the background.

import type { ChecklistItem } from "./types.js";

export type VerificationStage = "start" | "proof" | "review";
// blocks: the step can't happen. fails_item: that checklist item fails grading.
// poster_reviews: no automatic payment; the poster decides.
export type Enforcement = "blocks" | "fails_item" | "poster_reviews";

export interface VerificationSignal {
  id: "on_site_start" | "on_site_check_in" | "photo_location" | "fresh_photos" | "before_after" | "deliverable" | "deadline" | "ai_review";
  stage: VerificationStage;
  enforcement: Enforcement;
  title: string;
  detail: string;
  // What is recorded about the worker for this check, or null when nothing is.
  collects: string | null;
}

export interface VerificationPlan {
  summary: string;
  signals: VerificationSignal[];
  privacy: string;
}

export interface VerificationInput {
  remote: boolean;
  address?: string;
  checklist: ChecklistItem[];
}

export interface VerificationLimits {
  checkInRadiusM: number;
  photoRadiusM: number;
  confidence: number;
}

export function verificationPlan(job: VerificationInput, limits: VerificationLimits): VerificationPlan {
  const inPerson = !job.remote;
  const place = job.address?.trim() || "the job site";
  const photoItems = job.checklist.filter((i) => i.evidenceType === "PHOTO");
  const beforeAfter = photoItems.filter((i) => i.beforeAfter);
  const checkIns = job.checklist.filter((i) => i.evidenceType === "CHECK_IN");
  const deliverables = job.checklist.filter((i) => i.evidenceType === "FILE" || i.evidenceType === "LINK");
  const required = job.checklist.filter((i) => i.required).length || job.checklist.length;
  const signals: VerificationSignal[] = [];

  if (inPerson) {
    signals.push({
      id: "on_site_start",
      stage: "start",
      enforcement: "blocks",
      title: "On site to start",
      detail: `Start only works within ${limits.checkInRadiusM} m of ${place}, with a GPS fix accurate to ${limits.checkInRadiusM} m or better. The poster sees how far away the worker started.`,
      collects: "One GPS reading when the worker taps Start",
    });
  }
  if (checkIns.length > 0) {
    signals.push({
      id: "on_site_check_in",
      stage: "proof",
      enforcement: "fails_item",
      title: "Checked in at the job",
      detail: `The server compares the check-in with ${place} (within ${limits.checkInRadiusM} m). The AI isn't involved.`,
      collects: "One GPS reading at check-in",
    });
  }
  if (inPerson && photoItems.length > 0) {
    signals.push({
      id: "photo_location",
      stage: "proof",
      enforcement: "poster_reviews",
      title: "Photos taken on site",
      detail: `Proof photos record where they were taken. Any taken more than ${limits.photoRadiusM} m away, or without a location, send the job to the poster instead of paying automatically.`,
      collects: "The location of each proof photo",
    });
  }
  if (photoItems.length > 0) {
    signals.push({
      id: "fresh_photos",
      stage: "proof",
      enforcement: "blocks",
      title: "Taken in the Bounty camera",
      detail: "Photos and videos have to be taken in the app after the worker starts. Each is signed on the phone, so camera-roll or edited files are rejected, and so is anything already used for another job.",
      collects: "When each photo or video was taken, and a fingerprint of the file",
    });
  }
  if (beforeAfter.length > 0) {
    signals.push({
      id: "before_after",
      stage: "review",
      enforcement: "fails_item",
      title: "Before and after match",
      detail: `${count(beforeAfter.length, "item needs", "items need")} a photo before starting and after finishing. The AI checks they show the same spot.`,
      collects: null,
    });
  }
  if (deliverables.length > 0) {
    signals.push({
      id: "deliverable",
      stage: "review",
      enforcement: "fails_item",
      title: "Deliverable checked",
      detail: "Files and links are checked against what the job description asks for.",
      collects: "The files and links the worker submits",
    });
  }
  signals.push({
    id: "deadline",
    stage: "proof",
    enforcement: "blocks",
    title: "Done by the deadline",
    detail: "Proof can't be submitted after the deadline. If nobody finishes, the poster is refunded automatically.",
    collects: null,
  });
  signals.push({
    id: "ai_review",
    stage: "review",
    enforcement: "poster_reviews",
    title: "AI review, people decide doubts",
    detail: `The AI checks ${count(required, "required item", "required items")} and must be at least ${Math.round(limits.confidence * 100)}% confident in each. Anything uncertain goes to the poster, and nothing is paid until it's settled.`,
    collects: null,
  });

  return {
    summary: inPerson
      ? `Verified on site: location at start, ${photoItems.length > 0 ? "located photos, " : ""}and AI review of ${count(job.checklist.length, "item", "items")}.`
      : `Verified from the deliverable: AI review of ${count(job.checklist.length, "item", "items")}.`,
    signals,
    privacy: inPerson
      ? "Bounty never tracks location in the background. It reads GPS only when the worker taps Start, checks in, or takes a proof photo."
      : "This job is remote, so Bounty records no location at all.",
  };
}

const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
