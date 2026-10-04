// Text messages (iMessage through Photon Spectrum). The messenger service (messenger/) holds the
// Spectrum connection; this side only asks it to send. Inbound texts arrive at POST /internal/imessage.

import type { Config } from "../config.js";
import type { Logger } from "../lib/log.js";

export interface Messenger {
  // False when no messenger is configured: phone linking and job threads are off.
  readonly enabled: boolean;
  // Sends one text to an E.164 number. Throws when delivery is refused.
  send(to: string, text: string): Promise<void>;
}

export class HttpMessenger implements Messenger {
  readonly enabled = true;

  constructor(
    private readonly url: string,
    private readonly secret: string,
  ) {}

  async send(to: string, text: string): Promise<void> {
    const res = await fetch(new URL("/send", this.url), {
      method: "POST",
      headers: { "content-type": "application/json", "x-messenger-secret": this.secret },
      body: JSON.stringify({ to, text }),
      signal: AbortSignal.timeout(10_000),
    });
    if (!res.ok) throw new Error(`messenger send failed: ${res.status} ${await res.text()}`);
  }
}

// Local dev: print texts instead of sending them.
export class ConsoleMessenger implements Messenger {
  readonly enabled = true;

  constructor(private readonly log: Logger) {}

  async send(to: string, text: string): Promise<void> {
    this.log.info(`TEXT → ${to}: ${text}`);
  }
}

// Tests: remember what was sent.
export class RecordingMessenger implements Messenger {
  readonly enabled = true;
  readonly sent: { to: string; text: string }[] = [];

  async send(to: string, text: string): Promise<void> {
    this.sent.push({ to, text });
  }
}

export class DisabledMessenger implements Messenger {
  readonly enabled = false;

  async send(): Promise<void> {
    throw new Error("Texting isn't configured (set MESSENGER_URL and MESSENGER_SECRET)");
  }
}

export function createMessenger(config: Config, log: Logger): Messenger {
  if (config.MESSENGER_URL && config.MESSENGER_SECRET) return new HttpMessenger(config.MESSENGER_URL, config.MESSENGER_SECRET);
  return config.STAGE === "local" ? new ConsoleMessenger(log) : new DisabledMessenger();
}

// Inbound texts are routed to the account that last verified the number.
export const phoneKey = (number: string) => `phone:${number}`;

// "(734) 555-0100", "734-555-0100", "+1 734 555 0100" → "+17345550100". US numbers may omit +1.
export function normalizePhone(input: string): string | null {
  const trimmed = input.trim();
  const digits = trimmed.replace(/\D/g, "");
  if (trimmed.startsWith("+")) return digits.length >= 8 && digits.length <= 15 ? `+${digits}` : null;
  if (digits.length === 10) return `+1${digits}`;
  if (digits.length === 11 && digits.startsWith("1")) return `+${digits}`;
  return null;
}
