import { join } from "node:path";
import type { Config } from "../config.js";
import type { Blobs } from "./blobs.js";
import { LocalBlobs } from "./localBlobs.js";
import { S3Blobs } from "./s3Blobs.js";

export function createBlobs(config: Config): Blobs {
  if (config.BLOBS === "s3") {
    if (!config.BUCKET) throw new Error("BLOBS=s3 needs BUCKET");
    return new S3Blobs(config.AWS_REGION, config.BUCKET);
  }
  return new LocalBlobs(config.PUBLIC_BASE_URL, config.JWT_SECRET, config.DATA_DIR ? join(config.DATA_DIR, "blobs") : undefined);
}

// Upload size limits, checked when the upload is used (presigned PUTs cannot enforce size).
export const MAX_PHOTO_BYTES = 5 * 1024 * 1024;
export const MAX_FILE_BYTES = 20 * 1024 * 1024;
// Short proof videos from the in-app camera (about 20 seconds at medium quality).
export const MAX_VIDEO_BYTES = 60 * 1024 * 1024;

export * from "./blobs.js";
export { LocalBlobs } from "./localBlobs.js";
