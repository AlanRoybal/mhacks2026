import { GetObjectCommand, HeadObjectCommand, NoSuchKey, NotFound, PutObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";
import { DOWNLOAD_TTL_SEC, UPLOAD_TTL_SEC, type BlobInfo, type Blobs, type PresignedUpload } from "./blobs.js";

export class S3Blobs implements Blobs {
  private readonly s3: S3Client;

  constructor(
    region: string,
    private readonly bucket: string,
  ) {
    this.s3 = new S3Client({ region });
  }

  async presignPut(key: string, contentType: string): Promise<PresignedUpload> {
    const url = await getSignedUrl(this.s3, new PutObjectCommand({ Bucket: this.bucket, Key: key, ContentType: contentType }), {
      expiresIn: UPLOAD_TTL_SEC,
    });
    return { url, method: "PUT", headers: { "content-type": contentType }, expiresAt: new Date(Date.now() + UPLOAD_TTL_SEC * 1000).toISOString() };
  }

  presignGet(key: string): Promise<string> {
    return getSignedUrl(this.s3, new GetObjectCommand({ Bucket: this.bucket, Key: key }), { expiresIn: DOWNLOAD_TTL_SEC });
  }

  async get(key: string): Promise<Buffer | null> {
    try {
      const r = await this.s3.send(new GetObjectCommand({ Bucket: this.bucket, Key: key }));
      return r.Body ? Buffer.from(await r.Body.transformToByteArray()) : null;
    } catch (e) {
      if (e instanceof NoSuchKey) return null;
      throw e;
    }
  }

  async head(key: string): Promise<BlobInfo | null> {
    try {
      const r = await this.s3.send(new HeadObjectCommand({ Bucket: this.bucket, Key: key }));
      return { size: r.ContentLength ?? 0, etag: (r.ETag ?? "").replace(/"/g, ""), contentType: r.ContentType };
    } catch (e) {
      if (e instanceof NotFound || (e as { name?: string }).name === "NotFound") return null;
      throw e;
    }
  }
}
