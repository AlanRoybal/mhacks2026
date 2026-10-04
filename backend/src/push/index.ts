import type { Config } from "../config.js";
import type { Logger } from "../lib/log.js";
import { ApnsSender } from "./apns.js";
import type { PushMessage, PushSender } from "./push.js";

// Local dev: print pushes instead of sending them.
export class ConsolePushSender implements PushSender {
  constructor(private readonly log: Logger) {}

  async send(user: { userId: string; devices: unknown[] }, message: PushMessage) {
    this.log.info(`PUSH → ${user.userId}: ${message.title} — ${message.body}`, { type: message.type, devices: user.devices.length });
    return { deadTokens: [] };
  }
}

// Tests: remember what was sent.
export class RecordingPushSender implements PushSender {
  readonly sent: { userId: string; message: PushMessage }[] = [];

  async send(user: { userId: string }, message: PushMessage) {
    this.sent.push({ userId: user.userId, message });
    return { deadTokens: [] };
  }
}

export function createPushSender(config: Config, log: Logger): PushSender {
  if (config.PUSH_PROVIDER === "apns") {
    if (!config.APNS_KEY_ID || !config.APNS_TEAM_ID || !config.APNS_KEY_P8) {
      throw new Error("PUSH_PROVIDER=apns needs APNS_KEY_ID, APNS_TEAM_ID and APNS_KEY_P8");
    }
    return new ApnsSender({ keyId: config.APNS_KEY_ID, teamId: config.APNS_TEAM_ID, keyP8: config.APNS_KEY_P8, bundleId: config.APPLE_BUNDLE_ID }, log);
  }
  return new ConsolePushSender(log);
}

export * from "./push.js";
