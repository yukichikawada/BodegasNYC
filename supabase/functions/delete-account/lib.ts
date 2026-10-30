// delete-account (#127): deletes the caller's account, after revoking their
// Sign in with Apple token, then sweeps the photos they uploaded out of
// Storage. Everything here takes its I/O through `Deps` (an injected `fetch`
// and the environment), so lib_test.ts drives every path without a network.
//
// Order (spec item 2, eng D4 and D5, design DS6):
//   1. getUser(bearer). No or invalid bearer: 401. A bearer that verifies but
//      whose user is already gone (a lost 204, eng D5): owner sweep, 204.
//   2. If the user has an `apple` identity: a code is required (400
//      apple_code_required); exchange it at Apple (502 apple_exchange_failed);
//      the id_token's `sub` must be the caller's Apple identity (403
//      apple_identity_mismatch); revoke the refresh token (502
//      apple_revoke_failed). Nothing is deleted before this succeeds.
//   3. auth.admin.deleteUser (502 delete_failed). Cascades reviews, photos
//      and flags; bodegas.created_by becomes NULL.
//   4. Owner sweep: list the user's objects in the `photos` bucket with
//      `storage_paths_owned_by` (keyset pages) and remove them in batches of
//      up to 1,000. On failure, once more; then 202 cleanup_pending, since
//      the account itself is gone. (This replaces the spec's 502
//      storage_remove_failed: after deleteUser, a 5xx would be untrue.)
//   5. 204.
//
// Every step is idempotent, so the client simply calls again after an error.
// Never log the authorization code, tokens or the key: log lines carry the
// step and an HTTP status only.

import { importPKCS8, SignJWT } from "jose";

export type Fetch = (input: string | URL | Request, init?: RequestInit) => Promise<Response>;

export interface AppleConfig {
  clientId: string;
  teamId: string;
  keyId: string;
  /** PEM contents of the Sign in with Apple .p8 key. */
  privateKey: string;
}

export interface Env {
  supabaseUrl: string;
  serviceRoleKey: string;
  /** Absent when the APPLE_* secrets are not set (the local QA stack). */
  apple: AppleConfig | null;
}

export interface Deps {
  env: Env;
  fetch: Fetch;
  /** Seconds since the epoch; injectable for the client-secret test. */
  now?: () => number;
  log?: (line: string) => void;
}

export const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
export const APPLE_AUDIENCE = "https://appleid.apple.com";
export const PHOTOS_BUCKET = "photos";
/** Storage's `remove` takes at most 1,000 paths per call. */
export const REMOVE_BATCH_SIZE = 1000;
export const LIST_PAGE_SIZE = 1000;
/** The client secret lives five minutes: it is built per call. */
export const CLIENT_SECRET_LIFETIME_SECONDS = 300;

export type ErrorCode =
  | "bad_request"
  | "unauthorized"
  | "method_not_allowed"
  | "apple_code_required"
  | "apple_identity_mismatch"
  | "apple_exchange_failed"
  | "apple_revoke_failed"
  | "delete_failed";

const MESSAGES: Record<ErrorCode, string> = {
  bad_request: "The request body must be JSON with appleAuthorizationCode as a string or null.",
  unauthorized: "Sign in again, then delete.",
  method_not_allowed: "Use POST.",
  apple_code_required: "Confirm with Apple first.",
  apple_identity_mismatch: "Apple didn't confirm this account.",
  apple_exchange_failed: "Apple didn't accept the confirmation. The account wasn't deleted.",
  apple_revoke_failed: "Apple didn't revoke the sign-in. The account wasn't deleted.",
  delete_failed: "The account couldn't be deleted.",
};

const STATUS: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  method_not_allowed: 405,
  apple_code_required: 400,
  apple_identity_mismatch: 403,
  apple_exchange_failed: 502,
  apple_revoke_failed: 502,
  delete_failed: 502,
};

export function errorResponse(code: ErrorCode, message = MESSAGES[code]): Response {
  return jsonResponse(STATUS[code], { code, message });
}

function jsonResponse(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

/** 202: deleted, but the photo sweep failed twice (design DS6). */
export function cleanupPendingResponse(): Response {
  return jsonResponse(202, {
    code: "cleanup_pending",
    message: "The account is gone. Some photos will be removed later.",
  });
}

// MARK: - Environment

export function envFrom(get: (name: string) => string | undefined): Env {
  const supabaseUrl = get("SUPABASE_URL") ?? "";
  const serviceRoleKey = get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const clientId = get("APPLE_CLIENT_ID");
  const teamId = get("APPLE_TEAM_ID");
  const keyId = get("APPLE_KEY_ID");
  const privateKey = get("APPLE_PRIVATE_KEY");
  const apple = clientId && teamId && keyId && privateKey ? { clientId, teamId, keyId, privateKey } : null;
  return { supabaseUrl: supabaseUrl.replace(/\/+$/, ""), serviceRoleKey, apple };
}

// MARK: - Request validation

/** The bearer token, or null when the header is missing or not a bearer. */
export function bearerToken(request: Request): string | null {
  const header = request.headers.get("Authorization") ?? "";
  const match = header.match(/^Bearer\s+(\S+)$/i);
  return match ? match[1] : null;
}

/**
 * The Apple authorization code from the body: a string, or null when the
 * body says null, omits the key or is empty. Anything else is a bad request.
 */
export function parseAppleCode(bodyText: string): { ok: true; code: string | null } | { ok: false } {
  if (bodyText.trim() === "") return { ok: true, code: null };
  let body: unknown;
  try {
    body = JSON.parse(bodyText);
  } catch {
    return { ok: false };
  }
  if (typeof body !== "object" || body === null || Array.isArray(body)) return { ok: false };
  const value = (body as Record<string, unknown>).appleAuthorizationCode;
  if (value === undefined || value === null) return { ok: true, code: null };
  if (typeof value !== "string") return { ok: false };
  return { ok: true, code: value.length > 0 ? value : null };
}

// MARK: - Identity

export interface Identity {
  provider?: string;
  id?: string;
  identity_data?: Record<string, unknown> | null;
}

export interface AuthUser {
  id: string;
  identities?: Identity[] | null;
}

/** The caller's Apple user id (`sub`), or null without an apple identity. */
export function appleIdentityID(user: AuthUser): string | null {
  const identity = (user.identities ?? []).find((candidate) => candidate.provider === "apple");
  if (!identity) return null;
  const sub = identity.identity_data?.sub;
  if (typeof sub === "string" && sub.length > 0) return sub;
  return identity.id ?? null;
}

/** A JWT's payload, unverified. Only used on tokens a server already checked. */
export function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const parts = token.split(".");
  if (parts.length !== 3) return null;
  try {
    const base64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const json = new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0)));
    const payload = JSON.parse(json);
    return typeof payload === "object" && payload !== null ? payload : null;
  } catch {
    return null;
  }
}

/** True when Apple's id_token names the same Apple user as the identity. */
export function identityMatches(idToken: string, expectedSub: string): boolean {
  const payload = decodeJwtPayload(idToken);
  return typeof payload?.sub === "string" && payload.sub === expectedSub;
}

// MARK: - Apple

/**
 * The `client_secret` JWT for Apple's token and revoke endpoints: ES256,
 * `kid` = key id, `iss` = team id, `sub` = client id, `aud` = Apple, five
 * minutes from `nowSeconds`.
 */
export async function buildClientSecret(apple: AppleConfig, nowSeconds: number): Promise<string> {
  const key = await importPKCS8(apple.privateKey, "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: apple.keyId })
    .setIssuer(apple.teamId)
    .setSubject(apple.clientId)
    .setAudience(APPLE_AUDIENCE)
    .setIssuedAt(nowSeconds)
    .setExpirationTime(nowSeconds + CLIENT_SECRET_LIFETIME_SECONDS)
    .sign(key);
}

type AppleOutcome = { ok: true } | { ok: false; response: Response };

async function exchangeAndRevoke(deps: Deps, code: string, expectedSub: string): Promise<AppleOutcome> {
  const log = deps.log ?? console.error;
  const apple = deps.env.apple;
  if (!apple) {
    log("delete-account: apple step needed but APPLE_* secrets are not set");
    return {
      ok: false,
      response: errorResponse("apple_exchange_failed", "Sign in with Apple isn't configured on the server."),
    };
  }
  const nowSeconds = Math.floor((deps.now ?? (() => Date.now() / 1000))());
  let clientSecret: string;
  try {
    clientSecret = await buildClientSecret(apple, nowSeconds);
  } catch {
    log("delete-account: could not build the Apple client secret");
    return { ok: false, response: errorResponse("apple_exchange_failed") };
  }

  let tokens: { id_token?: unknown; refresh_token?: unknown; access_token?: unknown };
  try {
    const response = await deps.fetch(APPLE_TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: apple.clientId,
        client_secret: clientSecret,
        code,
        grant_type: "authorization_code",
      }),
    });
    if (response.status !== 200) {
      log(`delete-account: apple token exchange returned ${response.status}`);
      await response.body?.cancel();
      return { ok: false, response: errorResponse("apple_exchange_failed") };
    }
    tokens = await response.json();
  } catch {
    log("delete-account: apple token exchange failed or returned a malformed body");
    return { ok: false, response: errorResponse("apple_exchange_failed") };
  }
  if (typeof tokens?.id_token !== "string") {
    log("delete-account: apple token exchange returned no id_token");
    return { ok: false, response: errorResponse("apple_exchange_failed") };
  }
  if (!identityMatches(tokens.id_token, expectedSub)) {
    log("delete-account: apple id_token sub does not match the caller's apple identity");
    return { ok: false, response: errorResponse("apple_identity_mismatch") };
  }

  const refreshToken = typeof tokens.refresh_token === "string" ? tokens.refresh_token : null;
  const accessToken = typeof tokens.access_token === "string" ? tokens.access_token : null;
  const token = refreshToken ?? accessToken;
  if (!token) {
    log("delete-account: apple token exchange returned no token to revoke");
    return { ok: false, response: errorResponse("apple_exchange_failed") };
  }
  try {
    const response = await deps.fetch(APPLE_REVOKE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        client_id: apple.clientId,
        client_secret: clientSecret,
        token,
        token_type_hint: refreshToken ? "refresh_token" : "access_token",
      }),
    });
    await response.body?.cancel();
    if (response.status !== 200) {
      log(`delete-account: apple revoke returned ${response.status}`);
      return { ok: false, response: errorResponse("apple_revoke_failed") };
    }
  } catch {
    log("delete-account: apple revoke request failed");
    return { ok: false, response: errorResponse("apple_revoke_failed") };
  }
  return { ok: true };
}

// MARK: - Supabase (service role)

function serviceHeaders(env: Env, extra: Record<string, string> = {}): Record<string, string> {
  return { apikey: env.serviceRoleKey, Authorization: `Bearer ${env.serviceRoleKey}`, ...extra };
}

type CallerLookup =
  | { kind: "user"; user: AuthUser }
  | { kind: "gone"; userID: string }
  | { kind: "unauthorized" }
  | { kind: "error" };

/**
 * Resolves the bearer to a user. GoTrue checks the token's signature before
 * it looks the user up, so `user_not_found` means a valid token for a user
 * that no longer exists; the admin API confirms it before anything is swept
 * (eng D5). Any other refusal (expired, bad signature, a signed-out
 * session) is a 401.
 */
async function lookUpCaller(deps: Deps, bearer: string): Promise<CallerLookup> {
  const { env } = deps;
  const response = await deps.fetch(`${env.supabaseUrl}/auth/v1/user`, {
    headers: { apikey: env.serviceRoleKey, Authorization: `Bearer ${bearer}` },
  });
  if (response.status === 200) {
    const user = await response.json() as AuthUser;
    return typeof user?.id === "string" ? { kind: "user", user } : { kind: "error" };
  }
  let errorCode: unknown = null;
  try {
    const body = await response.json();
    errorCode = body?.error_code ?? body?.code;
  } catch {
    // Not JSON: treated as a refusal below.
  }
  if (response.status >= 500) return { kind: "error" };
  if (errorCode !== "user_not_found") return { kind: "unauthorized" };

  const sub = decodeJwtPayload(bearer)?.sub;
  if (typeof sub !== "string") return { kind: "unauthorized" };
  const admin = await deps.fetch(`${env.supabaseUrl}/auth/v1/admin/users/${encodeURIComponent(sub)}`, {
    headers: serviceHeaders(env),
  });
  await admin.body?.cancel();
  if (admin.status === 404) return { kind: "gone", userID: sub };
  return admin.status >= 500 ? { kind: "error" } : { kind: "unauthorized" };
}

/** Deletes the auth user; a 404 (already gone) counts as done. */
async function deleteUser(deps: Deps, userID: string): Promise<boolean> {
  const { env } = deps;
  const response = await deps.fetch(`${env.supabaseUrl}/auth/v1/admin/users/${encodeURIComponent(userID)}`, {
    method: "DELETE",
    headers: serviceHeaders(env, { "Content-Type": "application/json" }),
    body: JSON.stringify({ should_soft_delete: false }),
  });
  await response.body?.cancel();
  return response.ok || response.status === 404;
}

/** Every `photos` object the user owns, one keyset page at a time. */
export async function listOwnedPaths(deps: Deps, owner: string, pageSize = LIST_PAGE_SIZE): Promise<string[]> {
  const { env } = deps;
  const paths: string[] = [];
  let after: string | null = null;
  for (;;) {
    const response = await deps.fetch(`${env.supabaseUrl}/rest/v1/rpc/storage_paths_owned_by`, {
      method: "POST",
      headers: serviceHeaders(env, { "Content-Type": "application/json" }),
      body: JSON.stringify({ p_owner: owner, p_after: after, p_page_size: pageSize }),
    });
    if (!response.ok) {
      await response.body?.cancel();
      throw new Error(`storage_paths_owned_by returned ${response.status}`);
    }
    const page = await response.json();
    if (!Array.isArray(page) || !page.every((name) => typeof name === "string")) {
      throw new Error("storage_paths_owned_by returned a malformed page");
    }
    paths.push(...page);
    if (page.length < pageSize) return paths;
    after = page[page.length - 1];
  }
}

/** Removes `paths` from the photos bucket in batches of up to 1,000. */
export async function removePaths(deps: Deps, paths: string[]): Promise<void> {
  const { env } = deps;
  for (let start = 0; start < paths.length; start += REMOVE_BATCH_SIZE) {
    const batch = paths.slice(start, start + REMOVE_BATCH_SIZE);
    const response = await deps.fetch(`${env.supabaseUrl}/storage/v1/object/${PHOTOS_BUCKET}`, {
      method: "DELETE",
      headers: serviceHeaders(env, { "Content-Type": "application/json" }),
      body: JSON.stringify({ prefixes: batch }),
    });
    await response.body?.cancel();
    if (!response.ok) throw new Error(`storage remove returned ${response.status}`);
  }
}

/** The owner sweep, tried twice. True when everything listed was removed. */
async function sweepOwnedObjects(deps: Deps, owner: string): Promise<boolean> {
  const log = deps.log ?? console.error;
  for (let attempt = 1; attempt <= 2; attempt++) {
    try {
      await removePaths(deps, await listOwnedPaths(deps, owner));
      return true;
    } catch (error) {
      log(`delete-account: storage sweep attempt ${attempt} failed: ${(error as Error).message}`);
    }
  }
  return false;
}

// MARK: - Handler

export async function handleRequest(request: Request, deps: Deps): Promise<Response> {
  const log = deps.log ?? console.error;
  if (request.method !== "POST") return errorResponse("method_not_allowed");

  const bearer = bearerToken(request);
  if (!bearer) return errorResponse("unauthorized");

  const parsed = parseAppleCode(await request.text());
  if (!parsed.ok) return errorResponse("bad_request");

  let caller: CallerLookup;
  try {
    caller = await lookUpCaller(deps, bearer);
  } catch {
    caller = { kind: "error" };
  }
  switch (caller.kind) {
    case "unauthorized":
      return errorResponse("unauthorized");
    case "error":
      log("delete-account: could not look up the caller");
      return errorResponse("delete_failed", "The account couldn't be looked up. Nothing was deleted.");
    case "gone":
      // A lost 204: the account is already deleted. Finish the sweep.
      return await finishWithSweep(deps, caller.userID);
    case "user":
      break;
  }

  const user = caller.user;
  const appleSub = appleIdentityID(user);
  if (appleSub !== null) {
    if (parsed.code === null) return errorResponse("apple_code_required");
    const apple = await exchangeAndRevoke(deps, parsed.code, appleSub);
    if (!apple.ok) return apple.response;
  }

  let deleted = false;
  try {
    deleted = await deleteUser(deps, user.id);
  } catch {
    deleted = false;
  }
  if (!deleted) {
    log("delete-account: deleteUser failed");
    return errorResponse("delete_failed");
  }

  return await finishWithSweep(deps, user.id);
}

async function finishWithSweep(deps: Deps, userID: string): Promise<Response> {
  return (await sweepOwnedObjects(deps, userID)) ? new Response(null, { status: 204 }) : cleanupPendingResponse();
}
