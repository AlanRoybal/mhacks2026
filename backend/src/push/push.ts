import type { User } from "../domain/types.js";

// Must match PushNotificationDefinition in the iOS app (Bounty/App/PushNotificationManager.swift).
export const OFFER_CATEGORY = "BOUNTY_JOB_OFFER";

export interface PushMessage {
  title: string;
  body: string;
  // Template name; the app routes on it (and on jobId).
  type: string;
  jobId: string;
  offerId?: string;
  category?: string;
  timeSensitive?: boolean;
  // Do not deliver after this time (offers are useless once expired).
  expiresAt?: string;
}

export interface PushSender {
  // Sends to every device of the user. Never throws; returns tokens APNs says are dead.
  send(user: User, message: PushMessage): Promise<{ deadTokens: string[] }>;
}

export function apsPayload(message: PushMessage): Record<string, unknown> {
  return {
    aps: {
      alert: { title: message.title, body: message.body },
      sound: "default",
      ...(message.category ? { category: message.category, "mutable-content": 1 } : {}),
      "interruption-level": message.timeSensitive ? "time-sensitive" : "active",
      ...(message.timeSensitive ? { "relevance-score": 1 } : {}),
    },
    type: message.type,
    jobId: message.jobId,
    ...(message.offerId ? { offerId: message.offerId } : {}),
    // Same format as the API: no fractional seconds.
    ...(message.expiresAt ? { expiresAt: message.expiresAt.replace(/\.\d{3}Z$/, "Z") } : {}),
  };
}
