import { Hono } from "hono";
import { z } from "zod";
import { blobKeyFromFileUrl, fileUrl, verifyFileSignature } from "../../blobs/fileUrls.js";
import type { Deps } from "../../deps.js";
import { newId } from "../../domain/ids.js";
import { badRequest, forbidden } from "../../lib/errors.js";
import { parseBody, type AppEnv } from "../http.js";
import { wireDate } from "../wire.js";

const EXTENSIONS: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/heic": "heic",
  "application/pdf": "pdf",
  "application/zip": "zip",
};

// Accepts a blobKey, or a fileURL returned by /uploads/presign, and returns the caller's blob key.
export function ownedUploadKey(deps: Deps, userId: string, ref: { blobKey?: string; fileURL?: string }): string {
  const key = ref.blobKey ?? (ref.fileURL ? blobKeyFromFileUrl(deps.config, ref.fileURL) : null);
  if (!key || !key.startsWith(`uploads/${userId}/`)) throw badRequest("Unknown upload. Upload it through /uploads/presign first.", "unknown_upload");
  return key;
}

// POST /uploads/presign. PUT the bytes to uploadURL with exactly the returned headers, then use fileURL
// (stable, safe to store) or blobKey to refer to the file in other requests.
export function uploadRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();

  app.post("/presign", async (c) => {
    const { contentType } = await parseBody(c, z.object({ contentType: z.string() }));
    const ext = EXTENSIONS[contentType];
    if (!ext) throw badRequest(`Unsupported file type. Use one of: ${Object.keys(EXTENSIONS).join(", ")}`, "unsupported_type");
    const blobKey = `uploads/${c.get("user").userId}/${newId(deps.now().getTime())}.${ext}`;
    const upload = await deps.blobs.presignPut(blobKey, contentType);
    return c.json({
      uploadURL: upload.url,
      method: upload.method,
      headers: upload.headers,
      expiresAt: wireDate(upload.expiresAt),
      fileURL: fileUrl(deps.config, blobKey),
      blobKey,
    });
  });

  return app;
}

// GET /files/<key>?sig=... (public): redirects to a short-lived download URL.
export function fileRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  app.get("/*", async (c) => {
    const key = decodeURI(c.req.path.replace(/^\/files\//, ""));
    if (!verifyFileSignature(deps.config, key, c.req.query("sig"))) throw forbidden("Invalid file link");
    return c.redirect(await deps.blobs.presignGet(key), 302);
  });
  return app;
}
