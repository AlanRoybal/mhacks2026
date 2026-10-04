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
  not_enough_time: 409,
  window_closed: 409,
  location_required: 400,
  too_far: 422,
  location_imprecise: 422,
  deadline_passed: 409,
  too_early: 409,
  already_done: 409,
  bad_request: 400,
};

// Every error body is { error: { code: <stable code>, message: <human text> } }, the envelope TwinKit's
// APIClient decodes (Packages/TwinKit/Sources/TwinNetworking/APIClient.swift). Apps switch on `code`.
export function errorBody(code: string, message: string, extra: Record<string, unknown> = {}) {
  return { error: { code, message }, ...extra };
}

export function toErrorResponse(c: Context, err: unknown, deps: Deps): Response {
  if (err instanceof AppError) return c.json(errorBody(err.code, err.message), err.status);
  if (err instanceof TransitionError) return c.json(errorBody(err.code, err.message), TRANSITION_STATUS[err.code]);
  if (err instanceof VersionConflictError) return c.json(errorBody("busy", "Please try again"), 409);
  if (err instanceof z.ZodError) {
    const message = err.issues.map((i) => `${i.path.join(".") || "body"}: ${i.message}`).join("; ");
    return c.json(errorBody("invalid_request", message), 400);
  }
  deps.log.error("Unhandled error", { path: c.req.path, error: err });
  return c.json(errorBody("internal", "Something went wrong"), 500);
}

// Like parseBody, but an empty body counts as {} (for actions that take optional input).
export async function parseOptionalBody<T extends z.ZodType>(c: Context, schema: T): Promise<z.infer<T>> {
  const text = await c.req.text();
  if (!text.trim()) return schema.parse({});
  try {
    return schema.parse(JSON.parse(text));
  } catch (e) {
    if (e instanceof SyntaxError) throw badRequest("Body must be JSON", "invalid_request");
    throw e;
  }
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
