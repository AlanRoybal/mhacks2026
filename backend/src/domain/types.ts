// Records stored by the backend and returned (through views) to the iOS app.
// Money is always integer cents. Times are ISO-8601 strings in UTC.

import { z } from "zod";

export const JOB_STATES = [
  "DRAFT",
  "FUNDED",
  "OFFERED",
  "ACCEPTED",
  "IN_PROGRESS",
  "SUBMITTED",
  "IN_REVIEW",
  "DISPUTED",
  "RELEASED",
  "REFUNDED",
] as const;
export const JobState = z.enum(JOB_STATES);
export type JobState = z.infer<typeof JobState>;

export const TERMINAL_STATES: ReadonlySet<JobState> = new Set(["RELEASED", "REFUNDED"]);

// Matches the categories in the iOS create-job picker, plus a catch-all.
export const CATEGORIES = ["design", "home", "tutoring", "photography", "technology", "errands", "other"] as const;
export const Category = z.enum(CATEGORIES);
export type Category = z.infer<typeof Category>;

export const LatLng = z.object({
  lat: z.number().min(-90).max(90),
  lng: z.number().min(-180).max(180),
});
export type LatLng = z.infer<typeof LatLng>;

export const Place = LatLng.extend({ address: z.string().max(200).optional() });
export type Place = z.infer<typeof Place>;

export const EvidenceType = z.enum(["photo", "photo_pair", "location", "link", "file", "text"]);
export type EvidenceType = z.infer<typeof EvidenceType>;

export const ChecklistItem = z.object({
  id: z.string().min(1).max(40),
  text: z.string().min(1).max(300),
  evidence: EvidenceType,
  required: z.boolean(),
  angleHint: z.string().max(200).optional(),
});
export type ChecklistItem = z.infer<typeof ChecklistItem>;

// How a job is paid. "fake" settles instantly and is used for local dev and seed data.
export type Rail = "stripe" | "fake";

export type GradeDecision = "pass" | "fail" | "unclear";

export interface Rating {
  stars: number;
  comment?: string;
  at: string;
}

export interface Job {
  jobId: string;
  posterId: string;
  workerId?: string;
  title: string;
  description: string;
  category: Category;
  photos: string[];
  remote: boolean;
  location?: Place;
  radiusKm: number;
  deadline: string;
  estMinutes: number;
  bountyCents: number;
  feeCents: number;
  totalCents: number;
  rail: Rail;
  state: JobState;
  // Incremented on every transition. Writes are conditional on it (optimistic locking).
  version: number;
  checklist: ChecklistItem[];
  // Present exactly when state is OFFERED.
  currentOffer?: { offerId: string; workerId: string; expiresAt: string };
  // Workers who declined, let an offer expire, or withdrew. Never re-offered this job.
  excludedWorkerIds: string[];
  // One-time code that must be visible in proof photos. Issued on START.
  challenge?: { code: string; issuedAt: string };
  failedAttempts: number;
  latestProofId?: string;
  review?: {
    proofId: string;
    decision: GradeDecision;
    summary: string;
    // True when the AI was unsure or retries ran out. Blocks auto-release.
    requiresPosterAction: boolean;
    windowEndsAt: string;
  };
  dispute?: { itemId: string; reason: string; openedAt: string };
  resolution?: { outcome: "release" | "refund"; by: string; note?: string; at: string };
  payment: { paymentIntentId?: string; chargeId?: string; transferId?: string; refundId?: string };
  ratings: { byPoster?: Rating; byWorker?: Rating };
  matchRounds: number;
  createdAt: string;
  updatedAt: string;
  fundedAt?: string;
  acceptedAt?: string;
  startedAt?: string;
  submittedAt?: string;
  closedAt?: string;
}

export type OfferStatus = "queued" | "sent" | "accepted" | "declined" | "expired";

export interface Offer {
  offerId: string;
  jobId: string;
  workerId: string;
  round: number;
  rank: number;
  status: OfferStatus;
  fit: number;
  why: string;
  estMinutes: number;
  hourlyCents: number;
  distanceKm?: number;
  travelMinutes?: number;
  score: number;
  createdAt: string;
  sentAt?: string;
  expiresAt?: string;
  respondedAt?: string;
}

export type EvidencePhase = "before" | "after" | "single";
export type EvidenceKind = "photo" | "link" | "file" | "text" | "location";

export interface EvidenceItem {
  checklistItemId: string;
  phase: EvidencePhase;
  kind: EvidenceKind;
  blobKey?: string;
  url?: string;
  text?: string;
  contentType?: string;
  capturedAt?: string;
  lat?: number;
  lng?: number;
  etag?: string;
}

export interface ProofChecks {
  ok: boolean;
  missingRequired: string[];
  outsideTimeWindow: string[];
  outsideGeofence: string[];
  duplicates: string[];
  missingUploads: string[];
}

export interface ItemVerdict {
  itemId: string;
  verdict: GradeDecision;
  confidence: number;
  reason: string;
}

export interface Grade {
  decision: GradeDecision;
  decidedBecause: string;
  codeVisible: boolean;
  codeReadAs: string;
  items: ItemVerdict[];
  posterSummary: string;
  workerFeedback: string;
  model: string;
}

export interface Proof {
  jobId: string;
  proofId: string;
  workerId: string;
  attempt: number;
  items: EvidenceItem[];
  checks: ProofChecks;
  grade?: Grade;
  createdAt: string;
  gradedAt?: string;
}

export type SkillSourceKind = "linkedin" | "resume" | "email" | "user";

export interface Skill {
  // Lowercase, trimmed name. Used to merge the same skill from several sources.
  normName: string;
  name: string;
  category?: string;
  level: number;
  confidence: number;
  sources: { kind: SkillSourceKind; evidence: string }[];
  userEdited: boolean;
  // Tombstone: a deleted skill stays deleted when the résumé is imported again.
  deleted: boolean;
}

export interface Role {
  title: string;
  org?: string;
  start?: string;
  end?: string;
  summary?: string;
}

export interface Education {
  school: string;
  degree?: string;
  field?: string;
  end?: string;
}

export type IngestStatus = "idle" | "processing" | "done" | "failed";

export interface Twin {
  skills: Skill[];
  summary: string;
  roles: Role[];
  education: Education[];
  certifications: string[];
  yearsExperience: number;
  embedding?: number[];
  embeddingModel?: string;
  ingest: { status: IngestStatus; error?: string; sources: string[]; updatedAt: string };
  updatedAt: string;
}

export interface Prefs {
  minPayCents: number;
  maxRadiusKm: number;
  blockedCategories: Category[];
  remoteOk: boolean;
  inPersonOk: boolean;
  tz: string;
  // "HH:MM" in tz. No offers are sent inside this window.
  quietHours?: { start: string; end: string };
  // Where distance is measured from. The app sends the device location.
  base?: LatLng;
}

export interface Availability {
  tz: string;
  // 168 characters of "0"/"1": index = weekday * 24 + hour, weekday 0 = Monday, in tz.
  weekly?: string;
  busy: { start: string; end: string }[];
  updatedAt: string;
}

export interface Device {
  token: string;
  env: "sandbox" | "production";
  updatedAt: string;
}

export interface UserStats {
  offersReceived: number;
  offersAccepted: number;
  offersDeclined: number;
  offersExpired: number;
  jobsCompleted: number;
  jobsFailed: number;
  withdrawals: number;
  ratingSum: number;
  ratingCount: number;
  posterRatingSum: number;
  posterRatingCount: number;
}

export interface User {
  userId: string;
  version: number;
  displayName: string;
  email?: string;
  photoUrl?: string;
  identities: { linkedin?: string; apple?: string; demo?: string };
  twin: Twin;
  prefs: Prefs;
  availability?: Availability;
  devices: Device[];
  payouts: { stripeAccountId?: string; stripeTransfersEnabled: boolean };
  stats: UserStats;
  isAdmin?: boolean;
  // Seed users fill the marketplace but never receive offers.
  seed?: boolean;
  createdAt: string;
  updatedAt: string;
}

export type Actor =
  | { kind: "user"; userId: string }
  | { kind: "admin"; userId: string }
  | { kind: "system"; source: string };
