// Sessions are our own HS256 JWTs (30 days). Identity comes from LinkedIn OIDC, Sign in with Apple,
// or demo login (local dev and DEMO_MODE only).

import { Hono, type MiddlewareHandler } from "hono";
import { createRemoteJWKSet, jwtVerify, SignJWT } from "jose";
import { randomUUID } from "node:crypto";
import { z } from "zod";
import type { Deps } from "../deps.js";
import type { User } from "../domain/types.js";
import { badRequest, forbidden, unauthorized } from "../lib/errors.js";
import { newUser } from "../services/users.js";
import { parseBody, type AppEnv } from "./http.js";

const SESSION_DAYS = 30;
const LINKEDIN_ISSUER = "https://www.linkedin.com/oauth";
const linkedinJwks = createRemoteJWKSet(new URL("https://www.linkedin.com/oauth/openid/jwks"));
const appleJwks = createRemoteJWKSet(new URL("https://appleid.apple.com/auth/keys"));

const secretKey = (deps: Deps) => new TextEncoder().encode(deps.config.JWT_SECRET);

export async function signSession(deps: Deps, userId: string): Promise<string> {
  return new SignJWT({ typ: "session" })
    .setProtectedHeader({ alg: "HS256" })
    .setSubject(userId)
    .setIssuedAt()
    .setExpirationTime(`${SESSION_DAYS}d`)
    .sign(secretKey(deps));
}

export function requireAuth(deps: Deps): MiddlewareHandler<AppEnv> {
  return async (c, next) => {
    const header = c.req.header("authorization") ?? "";
    const token = header.startsWith("Bearer ") ? header.slice(7) : "";
    if (!token) throw unauthorized();
    let userId: string;
    try {
      const { payload } = await jwtVerify(token, secretKey(deps), { algorithms: ["HS256"] });
      if (payload.typ !== "session" || !payload.sub) throw new Error("not a session token");
      userId = payload.sub;
    } catch {
      throw unauthorized("Your session expired. Sign in again.");
    }
    const user = await deps.store.getUser(userId);
    if (!user) throw unauthorized("Account not found. Sign in again.");
    c.set("user", user);
    c.set("actor", { kind: "user", userId });
    await next();
  };
}

export function isAdmin(deps: Deps, user: User): boolean {
  return Boolean(user.isAdmin) || deps.config.adminUserIds.has(user.userId);
}

type Provider = "linkedin" | "apple" | "demo";

// Finds the user for an external identity, creating one on first sign-in.
async function upsertIdentity(
  deps: Deps,
  provider: Provider,
  subject: string,
  profile: { displayName: string; email?: string; photoUrl?: string; isAdmin?: boolean },
): Promise<User> {
  const key = `identity:${provider}:${subject}`;
  const existingId = await deps.store.kvGet<string>(key);
  if (existingId) {
    const existing = await deps.store.getUser(existingId);
    if (existing) return existing;
  }
  const user = newUser({ displayName: profile.displayName, email: profile.email, photoUrl: profile.photoUrl, identities: { [provider]: subject } }, deps.now());
  if (profile.isAdmin) user.isAdmin = true;
  await deps.store.createUser(user);
  // Two first sign-ins racing: the first mapping wins and the other new user is simply unused.
  if (!(await deps.store.kvPut(key, user.userId, { ifAbsent: true }))) {
    const winner = await deps.store.kvGet<string>(key);
    const winnerUser = winner ? await deps.store.getUser(winner) : null;
    if (winnerUser) return winnerUser;
  }
  deps.log.info("User created", { userId: user.userId, provider });
  return user;
}

const appRedirect = (deps: Deps, params: Record<string, string>) =>
  `${deps.config.APP_URL_SCHEME}://auth?${new URLSearchParams(params).toString()}`;

export function authRoutes(deps: Deps): Hono<AppEnv> {
  const app = new Hono<AppEnv>();
  const linkedinRedirectUri = `${deps.config.PUBLIC_BASE_URL}/auth/linkedin/callback`;

  // Demo login: stable personas by handle ("judge", "poster", "worker1"). Handle "admin" is an admin.
  app.post("/demo", async (c) => {
    if (!deps.config.DEMO_MODE && deps.config.STAGE !== "local") throw forbidden("Demo login is disabled");
    const body = await parseBody(c, z.object({ handle: z.string().regex(/^[a-z0-9_-]{2,32}$/), displayName: z.string().min(1).max(60).optional() }));
    const user = await upsertIdentity(deps, "demo", body.handle, {
      displayName: body.displayName ?? body.handle,
      isAdmin: body.handle === "admin",
    });
    return c.json({ token: await signSession(deps, user.userId), userId: user.userId });
  });

  // Open this URL in ASWebAuthenticationSession. It ends at <scheme>://auth?token=... or ?error=...
  app.get("/linkedin/start", async (c) => {
    if (!deps.config.LINKEDIN_CLIENT_ID) throw badRequest("LinkedIn sign-in is not configured", "not_configured");
    const nonce = randomUUID();
    const state = await new SignJWT({ typ: "oauth_state", nonce })
      .setProtectedHeader({ alg: "HS256" })
      .setExpirationTime("10m")
      .sign(secretKey(deps));
    const url = new URL("https://www.linkedin.com/oauth/v2/authorization");
    url.search = new URLSearchParams({
      response_type: "code",
      client_id: deps.config.LINKEDIN_CLIENT_ID,
      redirect_uri: linkedinRedirectUri,
      scope: "openid profile email",
      state,
      nonce,
    }).toString();
    return c.redirect(url.toString());
  });

  app.get("/linkedin/callback", async (c) => {
    const { code, state, error } = c.req.query();
    try {
      if (error || !code || !state) throw new Error(error ?? "missing code");
      const { payload: st } = await jwtVerify(state, secretKey(deps), { algorithms: ["HS256"] });
      if (st.typ !== "oauth_state") throw new Error("bad state");
      const tokenRes = await fetch("https://www.linkedin.com/oauth/v2/accessToken", {
        method: "POST",
        headers: { "content-type": "application/x-www-form-urlencoded" },
        body: new URLSearchParams({
          grant_type: "authorization_code",
          code,
          redirect_uri: linkedinRedirectUri,
          client_id: deps.config.LINKEDIN_CLIENT_ID ?? "",
          client_secret: deps.config.LINKEDIN_CLIENT_SECRET ?? "",
        }),
      });
      if (!tokenRes.ok) throw new Error(`token exchange failed: ${tokenRes.status}`);
      const { id_token } = (await tokenRes.json()) as { id_token?: string };
      if (!id_token) throw new Error("no id_token");
      const { payload } = await jwtVerify(id_token, linkedinJwks, { issuer: LINKEDIN_ISSUER, audience: deps.config.LINKEDIN_CLIENT_ID });
      if (payload.nonce !== st.nonce || !payload.sub) throw new Error("nonce mismatch");
      const user = await upsertIdentity(deps, "linkedin", payload.sub, {
        displayName: typeof payload.name === "string" ? payload.name : "LinkedIn user",
        email: typeof payload.email === "string" ? payload.email : undefined,
        photoUrl: typeof payload.picture === "string" ? payload.picture : undefined,
      });
      return c.redirect(appRedirect(deps, { token: await signSession(deps, user.userId) }));
    } catch (e) {
      deps.log.warn("LinkedIn sign-in failed", { error: e });
      return c.redirect(appRedirect(deps, { error: "linkedin_failed" }));
    }
  });

  // The app sends the identity token from ASAuthorizationAppleIDCredential.
  app.post("/apple", async (c) => {
    const body = await parseBody(c, z.object({ identityToken: z.string().min(10), fullName: z.string().max(80).optional() }));
    let payload;
    try {
      ({ payload } = await jwtVerify(body.identityToken, appleJwks, { issuer: "https://appleid.apple.com", audience: deps.config.APPLE_BUNDLE_ID }));
    } catch {
      throw unauthorized("Apple sign-in could not be verified");
    }
    if (!payload.sub) throw unauthorized("Apple sign-in could not be verified");
    const user = await upsertIdentity(deps, "apple", payload.sub, {
      displayName: body.fullName ?? "Bounty user",
      email: typeof payload.email === "string" ? payload.email : undefined,
    });
    return c.json({ token: await signSession(deps, user.userId), userId: user.userId });
  });

  return app;
}
