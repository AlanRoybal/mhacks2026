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

// An update to a Live Activity (the Lock Screen and Dynamic Island tracker), sent to the activity's own
// push token. contentState must match the app's BountyLiveAttributes.ContentState.
export interface LiveActivityPush {
  token: string;
  env: "sandbox" | "production";
  event: "update" | "end";
  contentState: Record<string, unknown>;
  // Unix seconds: when the content should be shown as out of date, and when an ended activity leaves.
  staleDate?: number;
  dismissalDate?: number;
  alert?: { title: string; body: string };
}

export interface PushSender {
  // Sends to every device of the user. Never throws; returns tokens APNs says are dead.
  send(user: User, message: PushMessage): Promise<{ deadTokens: string[] }>;
  // Never throws. "dead": APNs says the activity token is gone.
  liveActivity(push: LiveActivityPush, now: Date): Promise<"ok" | "dead" | "failed">;
}

export function liveActivityPayload(push: LiveActivityPush, now: Date): Record<string, unknown> {
  return {
    aps: {
      timestamp: Math.floor(now.getTime() / 1000),
      event: push.event,
      "content-state": push.contentState,
      ...(push.staleDate ? { "stale-date": push.staleDate } : {}),
      ...(push.dismissalDate ? { "dismissal-date": push.dismissalDate } : {}),
      ...(push.alert ? { alert: push.alert } : {}),
    },
  };
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
