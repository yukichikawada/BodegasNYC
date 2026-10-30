// deno test (from this directory): every path of the delete-account handler
// against an in-memory fake of GoTrue, PostgREST, Storage and Apple, driven
// through the injected `fetch`. No network. Each test states its card
// (spec AC 11): protects; fails_when; no_claim.

import { assert, assertEquals } from "@std/assert";
import { decodeProtectedHeader, exportPKCS8, generateKeyPair, jwtVerify } from "jose";
import {
  APPLE_REVOKE_URL,
  APPLE_TOKEN_URL,
  type AppleConfig,
  buildClientSecret,
  type Deps,
  handleRequest,
  LIST_PAGE_SIZE,
  parseAppleCode,
} from "./lib.ts";

const SUPABASE_URL = "http://supabase.test";
const SERVICE_KEY = "service-role-key-for-tests";
const USER_ID = "11111111-2222-4333-8444-555555555555";
const APPLE_SUB = "001234.abcdef0123456789.0042";

// MARK: - Fixtures

function fakeJwt(payload: Record<string, unknown>): string {
  const encode = (value: unknown) =>
    btoa(JSON.stringify(value)).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
  return `${encode({ alg: "HS256", typ: "JWT" })}.${encode(payload)}.signature`;
}

const USER_BEARER = fakeJwt({ sub: USER_ID, role: "authenticated" });

let cachedApple: AppleConfig | null = null;
async function appleConfig(): Promise<AppleConfig> {
  if (cachedApple) return cachedApple;
  const { privateKey } = await generateKeyPair("ES256", { extractable: true });
  cachedApple = {
    clientId: "Yukichi.BodegasNYC",
    teamId: "3BAMVTHBKF",
    keyId: "TESTKEY123",
    privateKey: await exportPKCS8(privateKey),
  };
  return cachedApple;
}

interface Call {
  method: string;
  url: string;
  body: string;
}

/**
 * A scripted backend. State: whether the user exists, their identities, the
 * objects they own; failures are queued per step and consumed one call at a
 * time ("fail revoke once").
 */
class FakeBackend {
  userExists = true;
  identities: unknown[] = [];
  objects: string[] = [];
  appleSubInToken = APPLE_SUB;
  failures: Record<string, number[]> = {};
  calls: Call[] = [];
  revoked: string[] = [];

  private nextFailure(step: string): number | null {
    const queue = this.failures[step];
    return queue && queue.length > 0 ? queue.shift()! : null;
  }

  fetch = (input: string | URL | Request, init?: RequestInit): Promise<Response> =>
    Promise.resolve(this.respond(input, init));

  private respond(input: string | URL | Request, init?: RequestInit): Response {
    const url = String(input);
    const method = init?.method ?? "GET";
    const body = init?.body == null ? "" : String(init.body);
    this.calls.push({ method, url, body });
    const json = (status: number, value: unknown) =>
      new Response(JSON.stringify(value), { status, headers: { "Content-Type": "application/json" } });

    if (url === APPLE_TOKEN_URL) {
      const failure = this.nextFailure("exchange");
      if (failure) return json(failure, { error: "invalid_grant" });
      return json(200, {
        access_token: "apple-access",
        refresh_token: "apple-refresh",
        id_token: fakeJwt({ sub: this.appleSubInToken, aud: "Yukichi.BodegasNYC" }),
      });
    }
    if (url === APPLE_REVOKE_URL) {
      const failure = this.nextFailure("revoke");
      if (failure) return new Response("", { status: failure });
      this.revoked.push(new URLSearchParams(body).get("token") ?? "");
      return new Response("", { status: 200 });
    }
    if (url === `${SUPABASE_URL}/auth/v1/user`) {
      const auth = new Headers(init?.headers).get("Authorization");
      if (auth !== `Bearer ${USER_BEARER}`) return json(401, { code: 401, error_code: "bad_jwt", msg: "invalid JWT" });
      if (!this.userExists) {
        return json(403, { code: 403, error_code: "user_not_found", msg: "User from sub claim in JWT does not exist" });
      }
      return json(200, { id: USER_ID, identities: this.identities });
    }
    if (url === `${SUPABASE_URL}/auth/v1/admin/users/${USER_ID}`) {
      if (method === "GET") {
        return this.userExists ? json(200, { id: USER_ID }) : json(404, { error_code: "user_not_found" });
      }
      const failure = this.nextFailure("delete");
      if (failure) return json(failure, { msg: "Database error deleting user" });
      this.userExists = false;
      return json(200, {});
    }
    if (url === `${SUPABASE_URL}/rest/v1/rpc/storage_paths_owned_by`) {
      const failure = this.nextFailure("list");
      if (failure) return json(failure, { message: "boom" });
      const { p_owner, p_after, p_page_size } = JSON.parse(body);
      assertEquals(p_owner, USER_ID);
      const page = [...this.objects].sort().filter((name) => p_after === null || name > p_after).slice(0, p_page_size);
      return json(200, page);
    }
    if (url === `${SUPABASE_URL}/storage/v1/object/photos` && method === "DELETE") {
      const failure = this.nextFailure("remove");
      if (failure) return json(failure, { message: "boom" });
      const { prefixes } = JSON.parse(body) as { prefixes: string[] };
      assert(prefixes.length <= 1000, `a remove batch carried ${prefixes.length} paths`);
      this.objects = this.objects.filter((name) => !prefixes.includes(name));
      return json(200, prefixes.map((name) => ({ name })));
    }
    throw new Error(`unexpected request ${method} ${url}`);
  }

  callsTo(urlSuffix: string, method?: string): Call[] {
    return this.calls.filter((call) => call.url.endsWith(urlSuffix) && (!method || call.method === method));
  }
}

async function makeDeps(backend: FakeBackend, withApple = true): Promise<Deps> {
  return {
    env: { supabaseUrl: SUPABASE_URL, serviceRoleKey: SERVICE_KEY, apple: withApple ? await appleConfig() : null },
    fetch: backend.fetch,
    now: () => 1_800_000_000,
    log: () => {},
  };
}

function deleteRequest(code: string | null, bearer: string | null = USER_BEARER, method = "POST"): Request {
  const headers: Record<string, string> = { "Content-Type": "application/json" };
  if (bearer) headers.Authorization = `Bearer ${bearer}`;
  return new Request("http://localhost/functions/v1/delete-account", {
    method,
    headers,
    body: method === "POST" ? JSON.stringify({ appleAuthorizationCode: code }) : undefined,
  });
}

const appleIdentity = { provider: "apple", id: APPLE_SUB, identity_data: { sub: APPLE_SUB } };
const emailIdentity = { provider: "email", id: USER_ID, identity_data: { sub: USER_ID } };

// MARK: - Tests

// protects=the client secret Apple's endpoints receive: ES256 signed by the
//   configured key, kid = key id, iss = team id, sub = client id, aud = Apple,
//   exp five minutes after iat;
// fails_when=a claim is wrong or missing, the lifetime exceeds 5 minutes, or
//   the signature does not verify with the key's public half;
// no_claim=that Apple accepts it (only a device test with the real .p8 can
//   show that).
Deno.test("client secret carries Apple's claims and a five-minute expiry", async () => {
  const { privateKey, publicKey } = await generateKeyPair("ES256", { extractable: true });
  const apple: AppleConfig = {
    clientId: "Yukichi.BodegasNYC",
    teamId: "3BAMVTHBKF",
    keyId: "ABC123DEFG",
    privateKey: await exportPKCS8(privateKey),
  };
  const now = 1_800_000_000;
  const secret = await buildClientSecret(apple, now);
  const header = decodeProtectedHeader(secret);
  assertEquals(header.alg, "ES256");
  assertEquals(header.kid, "ABC123DEFG");
  const { payload } = await jwtVerify(secret, publicKey, {
    issuer: "3BAMVTHBKF",
    audience: "https://appleid.apple.com",
    subject: "Yukichi.BodegasNYC",
    currentDate: new Date(now * 1000),
  });
  assertEquals(payload.iat, now);
  assert(payload.exp! - payload.iat! <= 300, "exp is more than five minutes after iat");
  assert(payload.exp! > payload.iat!, "exp is not after iat");
});

// protects=request validation: 405 for other methods, 401 without a bearer or
//   with one GoTrue rejects, 400 bad_request for a malformed body, 400
//   apple_code_required for an Apple user with no code; none of them reaches
//   Apple, deleteUser or Storage;
// fails_when=a bad request deletes, revokes or lists anything, or the status
//   or code differs;
// no_claim=Supabase's gateway JWT check (verify_jwt), which runs before the
//   function on the real stack.
Deno.test("bad requests are refused before anything is touched", async () => {
  const backend = new FakeBackend();
  backend.identities = [appleIdentity];
  backend.objects = ["b/1.jpg"];
  const deps = await makeDeps(backend);

  const get = await handleRequest(deleteRequest(null, USER_BEARER, "GET"), deps);
  assertEquals(get.status, 405);
  assertEquals((await get.json()).code, "method_not_allowed");

  const noBearer = await handleRequest(deleteRequest(null, null), deps);
  assertEquals(noBearer.status, 401);
  assertEquals((await noBearer.json()).code, "unauthorized");

  const badBearer = await handleRequest(deleteRequest(null, fakeJwt({ sub: "someone-else" })), deps);
  assertEquals(badBearer.status, 401);
  await badBearer.body?.cancel();

  const malformed = await handleRequest(
    new Request("http://localhost/", {
      method: "POST",
      headers: { Authorization: `Bearer ${USER_BEARER}` },
      body: JSON.stringify({ appleAuthorizationCode: 42 }),
    }),
    deps,
  );
  assertEquals(malformed.status, 400);
  assertEquals((await malformed.json()).code, "bad_request");

  const noCode = await handleRequest(deleteRequest(null), deps);
  assertEquals(noCode.status, 400);
  const noCodeBody = await noCode.json();
  assertEquals(noCodeBody.code, "apple_code_required");
  assertEquals(typeof noCodeBody.message, "string");

  assert(backend.userExists);
  assertEquals(backend.objects, ["b/1.jpg"]);
  assertEquals(backend.callsTo(APPLE_TOKEN_URL).length, 0);
  assertEquals(backend.callsTo(`/admin/users/${USER_ID}`, "DELETE").length, 0);
  assertEquals(backend.callsTo("/rpc/storage_paths_owned_by").length, 0);

  assertEquals(parseAppleCode(""), { ok: true, code: null });
  assertEquals(parseAppleCode('{"appleAuthorizationCode":null}'), { ok: true, code: null });
  assertEquals(parseAppleCode('{"appleAuthorizationCode":"c1"}'), { ok: true, code: "c1" });
  assertEquals(parseAppleCode("[1]"), { ok: false });
  assertEquals(parseAppleCode("{"), { ok: false });
});

// protects=AC 7: an Apple id_token whose sub is not the caller's Apple
//   identity is refused with 403 apple_identity_mismatch before revoke or
//   delete;
// fails_when=the function revokes, deletes or sweeps for a mismatched sub,
//   or answers anything but 403 with that code;
// no_claim=Apple's own id_token signature (the token comes straight from
//   Apple's token endpoint over TLS and is not re-verified).
Deno.test("an Apple identity mismatch is refused before revoke and delete", async () => {
  const backend = new FakeBackend();
  backend.identities = [emailIdentity, appleIdentity];
  backend.appleSubInToken = "000999.someone-else.0001";
  backend.objects = ["b/1.jpg"];
  const response = await handleRequest(deleteRequest("fresh-code"), await makeDeps(backend));

  assertEquals(response.status, 403);
  assertEquals((await response.json()).code, "apple_identity_mismatch");
  assertEquals(backend.callsTo(APPLE_TOKEN_URL).length, 1);
  assertEquals(backend.callsTo(APPLE_REVOKE_URL).length, 0);
  assert(backend.userExists);
  assertEquals(backend.objects, ["b/1.jpg"]);
});

// protects=AC 4 and 8 at the function level: a user without an Apple
//   identity (DEBUG email) is deleted with appleAuthorizationCode null and no
//   Apple call; the owner listing walks two keyset pages (1,000 + 500) and
//   the removal goes in batches of at most 1,000, leaving nothing behind;
//   deleteUser runs before the listing (eng D4);
// fails_when=Apple is called for an email user, a page is skipped or
//   repeated, a batch exceeds 1,000, an object survives, or the sweep runs
//   before deleteUser;
// no_claim=the real SQL function and Storage API (the local-stack check in
//   the PR test plan covers those).
Deno.test("an email user is deleted and every owned object is swept across pages", async () => {
  const backend = new FakeBackend();
  backend.identities = [emailIdentity];
  backend.objects = Array.from({ length: 1500 }, (_, i) => `bodega/${String(i).padStart(4, "0")}.jpg`);
  const response = await handleRequest(deleteRequest(null), await makeDeps(backend, false));

  assertEquals(response.status, 204);
  assertEquals(backend.callsTo(APPLE_TOKEN_URL).length, 0);
  assert(!backend.userExists);
  assertEquals(backend.objects, []);
  const listCalls = backend.callsTo("/rpc/storage_paths_owned_by");
  assertEquals(listCalls.length, 2);
  assertEquals(JSON.parse(listCalls[0].body).p_after, null);
  assertEquals(JSON.parse(listCalls[1].body).p_after, `bodega/${String(LIST_PAGE_SIZE - 1).padStart(4, "0")}.jpg`);
  assertEquals(backend.callsTo("/storage/v1/object/photos", "DELETE").length, 2);
  const deleteIndex = backend.calls.findIndex((call) => call.method === "DELETE" && call.url.includes("/admin/users/"));
  const firstListIndex = backend.calls.findIndex((call) => call.url.endsWith("/rpc/storage_paths_owned_by"));
  assert(deleteIndex >= 0 && deleteIndex < firstListIndex, "deleteUser must run before the sweep");
});

// protects=AC 7a: a revoke failure answers 502 apple_revoke_failed and
//   leaves the account and its objects in place; a second call with a fresh
//   code revokes Apple's refresh token, deletes and answers 204;
// fails_when=the first call deletes anything, answers another status, or the
//   retry does not complete;
// no_claim=Apple's real revoke semantics (device test under #139).
Deno.test("a revoke failure leaves the account intact and a retry completes", async () => {
  const backend = new FakeBackend();
  backend.identities = [appleIdentity];
  backend.objects = ["b/1.jpg", "b/2.jpg"];
  backend.failures.revoke = [500];
  const deps = await makeDeps(backend);

  const first = await handleRequest(deleteRequest("code-1"), deps);
  assertEquals(first.status, 502);
  assertEquals((await first.json()).code, "apple_revoke_failed");
  assert(backend.userExists);
  assertEquals(backend.objects.length, 2);
  assertEquals(backend.callsTo(`/admin/users/${USER_ID}`, "DELETE").length, 0);

  const second = await handleRequest(deleteRequest("code-2"), deps);
  assertEquals(second.status, 204);
  assertEquals(backend.revoked, ["apple-refresh"]);
  assert(!backend.userExists);
  assertEquals(backend.objects, []);
  const exchangeBodies = backend.callsTo(APPLE_TOKEN_URL).map((call) => new URLSearchParams(call.body));
  assertEquals(exchangeBodies.map((body) => body.get("code")), ["code-1", "code-2"]);
  assertEquals(exchangeBodies[1].get("grant_type"), "authorization_code");
  assertEquals(exchangeBodies[1].get("client_id"), "Yukichi.BodegasNYC");
});

// protects=design DS6 and eng D5: after deleteUser, a sweep that fails is
//   retried once (one failure still ends 204); failing twice answers 202
//   cleanup_pending, never a 5xx; a later call with the still-valid token of
//   the deleted user sweeps what is left and answers 204 without Apple or
//   deleteUser;
// fails_when=a sweep failure after the delete is reported as a failure the
//   client would show as "not deleted", there is no retry, or the
//   user-gone path re-runs Apple or deleteUser;
// no_claim=GoTrue's real error body for a deleted user's token (checked on
//   the local stack).
Deno.test("sweep failures after the delete: retry once, then 202; the gone path finishes it", async () => {
  const once = new FakeBackend();
  once.identities = [emailIdentity];
  once.objects = ["b/1.jpg"];
  once.failures.remove = [500];
  const onceResponse = await handleRequest(deleteRequest(null), await makeDeps(once, false));
  assertEquals(onceResponse.status, 204);
  assertEquals(once.objects, []);

  const backend = new FakeBackend();
  backend.identities = [appleIdentity];
  backend.objects = ["b/1.jpg", "b/2.jpg"];
  backend.failures.list = [503, 503];
  const deps = await makeDeps(backend);

  const first = await handleRequest(deleteRequest("code-1"), deps);
  assertEquals(first.status, 202);
  assertEquals((await first.json()).code, "cleanup_pending");
  assert(!backend.userExists);
  assertEquals(backend.objects.length, 2);

  const callsBefore = backend.calls.length;
  const second = await handleRequest(deleteRequest(null), deps);
  assertEquals(second.status, 204);
  assertEquals(backend.objects, []);
  const later = backend.calls.slice(callsBefore);
  assert(!later.some((call) => call.url === APPLE_TOKEN_URL || call.url === APPLE_REVOKE_URL));
  assert(!later.some((call) => call.method === "DELETE" && call.url.includes("/admin/users/")));
});

// protects=a deleteUser failure answers 502 delete_failed and does not sweep
//   (the account and its photos stay together);
// fails_when=objects are removed while the account still exists;
// no_claim=which database errors GoTrue reports as a failed delete.
Deno.test("a deleteUser failure answers 502 and sweeps nothing", async () => {
  const backend = new FakeBackend();
  backend.identities = [emailIdentity];
  backend.objects = ["b/1.jpg"];
  backend.failures.delete = [500];
  const response = await handleRequest(deleteRequest(null), await makeDeps(backend, false));
  assertEquals(response.status, 502);
  assertEquals((await response.json()).code, "delete_failed");
  assert(backend.userExists);
  assertEquals(backend.objects, ["b/1.jpg"]);
  assertEquals(backend.callsTo("/rpc/storage_paths_owned_by").length, 0);
});
