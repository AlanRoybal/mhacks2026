// Direct APNs over HTTP/2 with token (.p8) auth. Xcode builds register "sandbox" tokens and
// TestFlight builds "production" tokens; each goes to its own host. Mixing them up returns
// BadDeviceToken, which is the most common reason pushes "don't work".

import { connect, type ClientHttp2Session } from "node:http2";
import { importPKCS8, SignJWT } from "jose";
import type { Device, User } from "../domain/types.js";
import type { Logger } from "../lib/log.js";
import { apsPayload, type PushMessage, type PushSender } from "./push.js";

const HOSTS = { sandbox: "https://api.sandbox.push.apple.com", production: "https://api.push.apple.com" } as const;
const TOKEN_TTL_MS = 50 * 60 * 1000;
const DEAD_REASONS = new Set(["Unregistered", "BadDeviceToken", "DeviceTokenNotForTopic"]);

export interface ApnsConfig {
  keyId: string;
  teamId: string;
  keyP8: string;
  bundleId: string;
  // Tests point these at a local HTTP/2 server.
  hosts?: Record<Device["env"], string>;
  timeoutMs?: number;
}

class ApnsTimeout extends Error {}

export class ApnsSender implements PushSender {
  private token?: { value: string; at: number };
  private readonly sessions = new Map<string, ClientHttp2Session>();

  constructor(
    private readonly cfg: ApnsConfig,
    private readonly log: Logger,
  ) {}

  private async providerToken(): Promise<string> {
    if (!this.token || Date.now() - this.token.at > TOKEN_TTL_MS) {
      // Env vars often carry the key with literal "\n" sequences.
      const key = await importPKCS8(this.cfg.keyP8.replace(/\\n/g, "\n"), "ES256");
      const value = await new SignJWT({}).setProtectedHeader({ alg: "ES256", kid: this.cfg.keyId }).setIssuer(this.cfg.teamId).setIssuedAt().sign(key);
      this.token = { value, at: Date.now() };
    }
    return this.token.value;
  }

  private evict(env: Device["env"], session: ClientHttp2Session): void {
    if (this.sessions.get(env) === session) this.sessions.delete(env);
    if (!session.destroyed) session.destroy();
  }

  // Sessions are reused across pushes (and across warm Lambda invocations). One that went bad while
  // the Lambda was frozen is evicted on its first timeout or GOAWAY, and the push is retried.
  private session(env: Device["env"]): ClientHttp2Session {
    const existing = this.sessions.get(env);
    if (existing && !existing.closed && !existing.destroyed) return existing;
    const session = connect((this.cfg.hosts ?? HOSTS)[env]);
    session.on("error", (error) => {
      this.log.warn("APNs connection error", { env, error });
      this.evict(env, session);
    });
    session.on("goaway", () => this.evict(env, session));
    session.on("close", () => {
      if (this.sessions.get(env) === session) this.sessions.delete(env);
    });
    this.sessions.set(env, session);
    return session;
  }

  private async sendOne(device: Device, message: PushMessage): Promise<{ status: number; reason?: string }> {
    const token = await this.providerToken();
    const expiration = message.expiresAt ? Math.floor(Date.parse(message.expiresAt) / 1000) : 0;
    const session = this.session(device.env);
    return new Promise((resolve, reject) => {
      const req = session.request({
        ":method": "POST",
        ":path": `/3/device/${device.token}`,
        authorization: `bearer ${token}`,
        "apns-topic": this.cfg.bundleId,
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(expiration),
      });
      let status = 0;
      let body = "";
      req.setEncoding("utf8");
      req.on("response", (headers) => {
        status = Number(headers[":status"]);
      });
      req.on("data", (chunk: string) => {
        body += chunk;
      });
      req.on("end", () => {
        let reason: string | undefined;
        try {
          reason = body ? (JSON.parse(body) as { reason?: string }).reason : undefined;
        } catch {
          reason = body;
        }
        resolve({ status, reason });
      });
      req.on("error", reject);
      req.setTimeout(this.cfg.timeoutMs ?? 5_000, () => {
        req.close();
        this.evict(device.env, session);
        reject(new ApnsTimeout("APNs did not answer"));
      });
      req.end(JSON.stringify(apsPayload(message)));
    });
  }

  async send(user: User, message: PushMessage): Promise<{ deadTokens: string[] }> {
    const deadTokens: string[] = [];
    await Promise.all(
      user.devices.map(async (device) => {
        for (let attempt = 1; attempt <= 2; attempt++) {
          try {
            const { status, reason } = await this.sendOne(device, message);
            if (status === 200) return;
            if (status === 410 || (reason && DEAD_REASONS.has(reason))) deadTokens.push(device.token);
            this.log.warn("APNs rejected push", { userId: user.userId, env: device.env, status, reason });
            return;
          } catch (error) {
            // A dead connection: the session was evicted, so the retry opens a fresh one.
            if (attempt === 2) this.log.warn("APNs send failed", { userId: user.userId, error });
          }
        }
      }),
    );
    return { deadTokens };
  }
}
