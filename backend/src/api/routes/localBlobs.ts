// Serves LocalBlobs presigned URLs. Mounted only when BLOBS=local.
import { Hono } from "hono";
import type { LocalBlobs } from "../../blobs/index.js";
import { MAX_FILE_BYTES } from "../../blobs/index.js";
import { AppError, forbidden, notFound } from "../../lib/errors.js";
import type { AppEnv } from "../http.js";

export function localBlobRoutes(blobs: LocalBlobs): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const keyOf = (path: string) => decodeURI(path.replace(/^\/local-blobs\//, ""));

  app.put("/*", async (c) => {
    const key = keyOf(c.req.path);
    if (!blobs.verify("PUT", key, c.req.query("exp"), c.req.query("sig"))) throw forbidden("Upload link expired or invalid");
    const bytes = Buffer.from(await c.req.arrayBuffer());
    if (bytes.length > MAX_FILE_BYTES) throw new AppError(422, "too_large", "File is too large");
    await blobs.put(key, bytes, c.req.header("content-type"));
    return c.body(null, 200);
  });

  app.get("/*", async (c) => {
    const key = keyOf(c.req.path);
    if (!blobs.verify("GET", key, c.req.query("exp"), c.req.query("sig"))) throw forbidden("Download link expired or invalid");
    const bytes = await blobs.get(key);
    if (!bytes) throw notFound("File");
    return c.body(new Uint8Array(bytes), 200, { "content-type": (await blobs.contentType(key)) ?? "application/octet-stream" });
  });

  return app;
}
