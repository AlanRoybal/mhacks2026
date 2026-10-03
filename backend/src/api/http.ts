import type { Context } from "hono";
import type { ContentfulStatusCode } from "hono/utils/http-status";
import { z } from "zod";
import type { Deps } from "../deps.js";
import { TransitionError, type TransitionErrorCode } from "../domain/jobMachine.js";
import type { Actor, User } from "../domain/types.js";
import { AppError, badRequest } from "../lib/errors.js";
import { VersionConflictError } from "../store/index.js";

// Variables set by the auth middleware.
export interface AppEnv {
  Variables: { user: User; actor: Actor };
}

const TRANSITION_STATUS: Record<TransitionErrorCode, ContentfulStatusCode> = {
  invalid_transition: 409,
  forbidden: 403,
  offer_not_current: 409,
  offer_expired: 409,
  location_required: 400,
  too_far: 422,
  deadline_passed: 409,
  too_early: 409,
  already_done: 409,
  bad_request: 400,
};

// Every error body is { error: <stable code>, message: <human text> }. The app switches on `error`.
export function toErrorResponse(c: Context, err: unknown, deps: Deps): Response {
  if (err instanceof AppError) return c.json({ error: err.code, message: err.message }, err.status);
  if (err instanceof TransitionError) return c.json({ error: err.code, message: err.message }, TRANSITION_STATUS[err.code]);
  if (err instanceof VersionConflictError) return c.json({ error: "busy", message: "Please try again" }, 409);
  if (err instanceof z.ZodError) {
    const message = err.issues.map((i) => `${i.path.join(".") || "body"}: ${i.message}`).join("; ");
    return c.json({ error: "invalid_request", message }, 400);
  }
  deps.log.error("Unhandled error", { path: c.req.path, error: err });
  return c.json({ error: "internal", message: "Something went wrong" }, 500);
}

export async function parseBody<T extends z.ZodType>(c: Context, schema: T): Promise<z.infer<T>> {
  let raw: unknown;
  try {
    raw = await c.req.json();
  } catch {
    throw badRequest("Body must be JSON", "invalid_request");
  }
  return schema.parse(raw);
}
