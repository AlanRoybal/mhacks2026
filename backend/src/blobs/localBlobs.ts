// Local stand-in for S3. "Presigned" URLs point at this API (/local-blobs/...) with an HMAC signature,
// so the iOS app uses exactly the same upload flow against a laptop as against AWS.

import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve, sep } from "node:path";
import { DOWNLOAD_TTL_SEC, UPLOAD_TTL_SEC, type BlobInfo, type Blobs, type PresignedUpload } from "./blobs.js";

interface Stored {
  bytes: Buffer;
  contentType?: string;
}

export class LocalBlobs implements Blobs {
  private readonly memory = new Map<string, Stored>();

  constructor(
    private readonly baseUrl: string,
    private readonly secret: string,
    private readonly dir?: string,
  ) {}

  private sign(method: string, key: string, exp: number): string {
    return createHmac("sha256", this.secret).update(`${method}\n${key}\n${exp}`).digest("hex");
  }

  private signedUrl(method: string, key: string, ttlSec: number): { url: string; exp: number } {
    const exp = Math.floor(Date.now() / 1000) + ttlSec;
    const url = `${this.baseUrl}/local-blobs/${encodeURI(key)}?exp=${exp}&sig=${this.sign(method, key, exp)}`;
    return { url, exp };
  }

  verify(method: string, key: string, exp: string | undefined, sig: string | undefined): boolean {
    const expNum = Number(exp);
    if (!sig || !Number.isFinite(expNum) || expNum < Date.now() / 1000) return false;
    const expected = Buffer.from(this.sign(method, key, expNum));
    const given = Buffer.from(sig);
    return expected.length === given.length && timingSafeEqual(expected, given);
  }

  async presignPut(key: string, contentType: string): Promise<PresignedUpload> {
    const { url, exp } = this.signedUrl("PUT", key, UPLOAD_TTL_SEC);
    return { url, method: "PUT", headers: { "content-type": contentType }, expiresAt: new Date(exp * 1000).toISOString() };
  }

  async presignGet(key: string): Promise<string> {
    return this.signedUrl("GET", key, DOWNLOAD_TTL_SEC).url;
  }

  private path(key: string): string | undefined {
    if (!this.dir) return undefined;
    const root = resolve(this.dir);
    const full = resolve(join(root, key));
    if (!full.startsWith(root + sep)) throw new Error(`Blob key escapes the storage folder: ${key}`);
    return full;
  }

  async put(key: string, bytes: Buffer, contentType?: string): Promise<void> {
    const path = this.path(key);
    if (path) {
      mkdirSync(dirname(path), { recursive: true });
      writeFileSync(path, bytes);
      writeFileSync(`${path}.meta.json`, JSON.stringify({ contentType }));
    } else {
      this.memory.set(key, { bytes, contentType });
    }
  }

  private read(key: string): Stored | null {
    const path = this.path(key);
    if (!path) return this.memory.get(key) ?? null;
    if (!existsSync(path)) return null;
    const meta = existsSync(`${path}.meta.json`) ? (JSON.parse(readFileSync(`${path}.meta.json`, "utf8")) as { contentType?: string }) : {};
    return { bytes: readFileSync(path), contentType: meta.contentType };
  }

  async get(key: string): Promise<Buffer | null> {
    return this.read(key)?.bytes ?? null;
  }

  async head(key: string): Promise<BlobInfo | null> {
    const stored = this.read(key);
    if (!stored) return null;
    // Same as S3 for single-part uploads: the ETag is the MD5 of the bytes.
    return { size: stored.bytes.length, etag: createHash("md5").update(stored.bytes).digest("hex"), contentType: stored.contentType };
  }

  async contentType(key: string): Promise<string | undefined> {
    return this.read(key)?.contentType;
  }
}
