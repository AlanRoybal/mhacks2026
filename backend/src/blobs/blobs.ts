// File storage for résumés, job photos and proof evidence. The app uploads and downloads directly
// with short-lived presigned URLs; the API never proxies file bytes in production.

export interface PresignedUpload {
  url: string;
  method: "PUT";
  // Headers the app must send with the PUT, exactly as given.
  headers: Record<string, string>;
  expiresAt: string;
}

export interface BlobInfo {
  size: number;
  etag: string;
  contentType?: string;
}

export interface Blobs {
  presignPut(key: string, contentType: string): Promise<PresignedUpload>;
  presignGet(key: string): Promise<string>;
  get(key: string): Promise<Buffer | null>;
  head(key: string): Promise<BlobInfo | null>;
}

export const UPLOAD_TTL_SEC = 300;
export const DOWNLOAD_TTL_SEC = 900;
