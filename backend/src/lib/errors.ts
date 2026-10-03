// Errors that map to HTTP responses. TransitionError (domain/jobMachine.ts) is mapped separately.

export class AppError extends Error {
  constructor(
    readonly status: 400 | 401 | 403 | 404 | 409 | 422 | 501 | 502,
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "AppError";
  }
}

export const notFound = (what: string) => new AppError(404, "not_found", `${what} not found`);
export const forbidden = (message = "You cannot do this") => new AppError(403, "forbidden", message);
export const badRequest = (message: string, code = "bad_request") => new AppError(400, code, message);
export const conflict = (code: string, message: string) => new AppError(409, code, message);
export const unauthorized = (message = "Sign in first") => new AppError(401, "unauthorized", message);
