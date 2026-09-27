import { afterEach, beforeAll, beforeEach, describe, expect, setSystemTime, test } from "bun:test";
import { FCM_SCOPE, parseServiceAccount, type ServiceAccount } from "../src/oauth.ts";
import { createRelay, type Relay } from "../src/relay.ts";

const TOKEN_URI = "https://oauth2.test/token";
const FCM_ORIGIN = "https://fcm.test";
const SEND_URL = `${FCM_ORIGIN}/v1/projects/demo-project/messages:send`;
const CLIENT_EMAIL = "relay@demo-project.iam.gserviceaccount.com";

// From the contract's test vector.
const NONCE = "oKGio6Slpqeoqaqr";
const CIPHERTEXT =
  "nToKD3/6Lp0JDOm3JUDiuh/CPDK+lS8N/2ZP6BriESPoVCrOjQ5xTyryTawrQKGLdjlqahG1aQ0oMWUOxQTtko6eqgdfyIHPgc3Rd+K+49uqbsXQ6rL8CZ0cUfTCtTW7vttKhWnd4PXy+Spy8eGZREFyW4yYXOMcW6e7hMQ0gD6gY5JT8TH1dUMwiud3aKv07LzbCdGo2k5K7fmawaIWB+R6cNXPSHo0w2ZHAhu3xZUEBo35cRWAHK6gAkp+uC5gDQZ8+VDhi93DbXCyNzdjdu8yZsnjEAE6Fz78cw==";
const FID = "eQ1bN4xRS0qZ8k2Yb7cT9w";
const VALID = { fid: FID, platform: "android", nonce: NONCE, ciphertext: CIPHERTEXT };

let account: ServiceAccount;
let publicKey: CryptoKey;

beforeAll(async () => {
  const pair = await crypto.subtle.generateKey(
    { name: "RSASSA-PKCS1-v1_5", modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: "SHA-256" },
    true,
    ["sign", "verify"],
  );
  publicKey = pair.publicKey;
  const der = Buffer.from(await crypto.subtle.exportKey("pkcs8", pair.privateKey)).toString("base64");
  const pem = `-----BEGIN PRIVATE KEY-----\n${(der.match(/.{1,64}/g) ?? []).join("\n")}\n-----END PRIVATE KEY-----\n`;
  account = await parseServiceAccount(
    JSON.stringify({
      type: "service_account",
      project_id: "demo-project",
      private_key_id: "0123456789abcdef",
      private_key: pem,
      client_email: CLIENT_EMAIL,
      token_uri: TOKEN_URI,
    }),
  );
});

type Call = { url: string; init: RequestInit | undefined };
let calls: Call[];
let tokenReply: () => Response;
let fcmReply: () => Response | Promise<Response>;
let relay: Relay;

const realFetch = globalThis.fetch;
const exchanges = () => calls.filter((call) => call.url === TOKEN_URI);
const sends = () => calls.filter((call) => call.url === SEND_URL);

beforeEach(() => {
  calls = [];
  tokenReply = () =>
    Response.json({ access_token: `access-${exchanges().length}`, expires_in: 3599, token_type: "Bearer" });
  fcmReply = () => Response.json({ name: "projects/demo-project/messages/0:1" });
  const fake = async (input: string | URL | Request, init?: RequestInit): Promise<Response> => {
    const url = String(input);
    calls.push({ url, init });
    if (url === TOKEN_URI) return tokenReply();
    if (url === SEND_URL) return fcmReply();
    throw new Error(`unexpected fetch ${url}`);
  };
  globalThis.fetch = Object.assign(fake, { preconnect: realFetch.preconnect });
  relay = createRelay(account, FCM_ORIGIN);
});

afterEach(() => {
  globalThis.fetch = realFetch;
  setSystemTime();
});

function post(body: BodyInit, contentType = "application/json"): Request {
  return new Request("http://relay.test/v1/send", { method: "POST", headers: { "content-type": contentType }, body });
}

async function send(body: unknown, ip = "198.51.100.7"): Promise<Response> {
  return relay(post(JSON.stringify(body)), ip);
}

function jsonBody(call: Call | undefined): unknown {
  return JSON.parse(String(call?.init?.body));
}

describe("validation", () => {
  const cases: [string, () => Request][] = [
    ["a Content-Type other than JSON", () => post(JSON.stringify(VALID), "text/plain")],
    ["a body over 8 KiB", () => post(JSON.stringify({ ...VALID, fid: "f".repeat(8200) }))],
    [
      "a chunked body over 8 KiB",
      () =>
        post(
          new ReadableStream<Uint8Array>({
            start(controller) {
              controller.enqueue(new Uint8Array(5000).fill(0x20));
              controller.enqueue(new Uint8Array(5000).fill(0x20));
              controller.close();
            },
          }),
        ),
    ],
    ["a body that is not JSON", () => post("{")],
    ["a JSON array", () => post("[]")],
    ["a missing field", () => post(JSON.stringify({ fid: FID, platform: "ios", nonce: NONCE }))],
    ["token in place of fid", () => post(JSON.stringify({ ...VALID, fid: undefined, token: FID }))],
    ["an unknown field", () => post(JSON.stringify({ ...VALID, collapseKey: "x" }))],
    ["a platform outside the enum", () => post(JSON.stringify({ ...VALID, platform: "web" }))],
    ["an empty fid", () => post(JSON.stringify({ ...VALID, fid: "" }))],
    ["an fid that is not a string", () => post(JSON.stringify({ ...VALID, fid: 7 }))],
    ["an fid over 256 characters", () => post(JSON.stringify({ ...VALID, fid: "f".repeat(257) }))],
    ["a nonce of 8 bytes", () => post(JSON.stringify({ ...VALID, nonce: "AAAAAAAAAAA=" }))],
    ["a nonce of 16 bytes", () => post(JSON.stringify({ ...VALID, nonce: "AAAAAAAAAAAAAAAAAAAAAA==" }))],
    ["a nonce that is not base64", () => post(JSON.stringify({ ...VALID, nonce: "oKGio6Slpqeoqaq!" }))],
    ["an empty ciphertext", () => post(JSON.stringify({ ...VALID, ciphertext: "" }))],
    ["a ciphertext that is not base64", () => post(JSON.stringify({ ...VALID, ciphertext: "not base64!" }))],
    ["a ciphertext without padding", () => post(JSON.stringify({ ...VALID, ciphertext: "YWJjZA" }))],
    ["a ciphertext over 3,072 characters", () => post(JSON.stringify({ ...VALID, ciphertext: "AAAA".repeat(769) }))],
  ];

  test.each(cases)("400 for %s, and nothing sent", async (_, request) => {
    const response = await relay(request(), "198.51.100.7");
    expect(response.status).toBe(400);
    expect(await response.json()).toEqual({ error: expect.any(String) });
    expect(calls).toEqual([]);
  });

  test("the largest fid and ciphertext the contract allows go through", async () => {
    const response = await send({ ...VALID, fid: "f".repeat(256), ciphertext: "AAAA".repeat(768) });
    expect(response.status).toBe(204);
  });

  test("other paths are 404 and other methods on /v1/send are 405", async () => {
    expect((await relay(new Request("http://relay.test/v1/other", { method: "POST" }), "ip")).status).toBe(404);
    const get = await relay(new Request("http://relay.test/v1/send"), "ip");
    expect(get.status).toBe(405);
    expect(get.headers.get("allow")).toBe("POST");
    expect((await relay(new Request("http://relay.test/healthz"), "ip")).status).toBe(200);
  });
});

describe("the FCM message", () => {
  test("android: a high-priority data message with a day's TTL", async () => {
    expect((await send(VALID)).status).toBe(204);
    const [call] = sends();
    expect(call?.init?.method).toBe("POST");
    expect(new Headers(call?.init?.headers).get("authorization")).toBe("Bearer access-1");
    expect(jsonBody(call)).toEqual({
      message: {
        fid: FID,
        data: { v: "1", n: NONCE, c: CIPHERTEXT },
        android: { priority: "HIGH", ttl: "86400s" },
      },
    });
  });

  test("ios: a mutable alert with the placeholder, expiring a day from now", async () => {
    setSystemTime(new Date(1_790_000_000_500));
    expect((await send({ ...VALID, platform: "ios" })).status).toBe(204);
    expect(jsonBody(sends()[0])).toEqual({
      message: {
        fid: FID,
        apns: {
          headers: { "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "1790086400" },
          payload: {
            aps: { alert: { title: "ompanion", body: "Session update" }, "mutable-content": 1, sound: "default" },
            v: 1,
            n: NONCE,
            c: CIPHERTEXT,
          },
        },
      },
    });
  });
});

describe("FCM responses", () => {
  const fcmError = (status: number, error: Record<string, unknown>, headers: Record<string, string> = {}) => () =>
    Response.json({ error: { code: status, ...error } }, { status, headers });
  const fcmDetail = (errorCode: string) => ({
    "@type": "type.googleapis.com/google.firebase.fcm.v1.FcmError",
    errorCode,
  });
  const badRequest = (field: string) => ({
    "@type": "type.googleapis.com/google.rpc.BadRequest",
    fieldViolations: [{ field, description: "Invalid value" }],
  });

  const cases: [string, () => Response | Promise<Response>, number][] = [
    ["success", () => Response.json({ name: "projects/demo-project/messages/1" }), 204],
    [
      "UNREGISTERED",
      fcmError(404, {
        status: "NOT_FOUND",
        message: "Requested entity was not found.",
        details: [fcmDetail("UNREGISTERED")],
      }),
      410,
    ],
    [
      "INVALID_ARGUMENT naming message.fid",
      fcmError(400, {
        status: "INVALID_ARGUMENT",
        message: "Invalid Firebase installation ID",
        details: [fcmDetail("INVALID_ARGUMENT"), badRequest("message.fid")],
      }),
      410,
    ],
    [
      "INVALID_ARGUMENT about another field",
      fcmError(400, {
        status: "INVALID_ARGUMENT",
        message: "Invalid value at 'message.data'",
        details: [fcmDetail("INVALID_ARGUMENT"), badRequest("message.data")],
      }),
      502,
    ],
    ["a bare NOT_FOUND (wrong project)", fcmError(404, { status: "NOT_FOUND", message: "Not found" }), 502],
    [
      "SENDER_ID_MISMATCH",
      fcmError(403, { status: "PERMISSION_DENIED", details: [fcmDetail("SENDER_ID_MISMATCH")] }),
      502,
    ],
    [
      "THIRD_PARTY_AUTH_ERROR",
      fcmError(401, { status: "UNAUTHENTICATED", details: [fcmDetail("THIRD_PARTY_AUTH_ERROR")] }),
      502,
    ],
    ["UNAVAILABLE as HTML", () => new Response("<html>busy</html>", { status: 503 }), 502],
    ["INTERNAL", fcmError(500, { status: "INTERNAL", details: [fcmDetail("INTERNAL")] }), 502],
    [
      "a network error",
      () => {
        throw new TypeError("fetch failed");
      },
      502,
    ],
  ];

  test.each(cases)("%s → %d", async (_, reply, status) => {
    fcmReply = reply;
    const response = await send(VALID);
    expect(response.status).toBe(status);
    if (status !== 204) expect(await response.json()).toEqual({ error: expect.any(String) });
  });

  test("QUOTA_EXCEEDED → 429 with FCM's Retry-After", async () => {
    fcmReply = fcmError(
      429,
      { status: "RESOURCE_EXHAUSTED", details: [fcmDetail("QUOTA_EXCEEDED")] },
      { "retry-after": "60" },
    );
    const response = await send(VALID);
    expect(response.status).toBe(429);
    expect(response.headers.get("retry-after")).toBe("60");
  });

  test("a failed token exchange → 502", async () => {
    tokenReply = () =>
      Response.json({ error: "invalid_grant", error_description: "Invalid JWT Signature." }, { status: 400 });
    const response = await send(VALID);
    expect(response.status).toBe(502);
    expect(((await response.json()) as { error: string }).error).toContain("invalid_grant");
  });
});

describe("the access token", () => {
  test("is exchanged once for two sends, with a signed JWT for the FCM scope", async () => {
    setSystemTime(new Date(1_790_000_000_000));
    expect((await send(VALID)).status).toBe(204);
    expect((await send(VALID)).status).toBe(204);
    expect(exchanges()).toHaveLength(1);
    expect(sends().map((call) => new Headers(call.init?.headers).get("authorization"))).toEqual([
      "Bearer access-1",
      "Bearer access-1",
    ]);

    const form = new URLSearchParams(String(exchanges()[0]?.init?.body));
    expect(form.get("grant_type")).toBe("urn:ietf:params:oauth:grant-type:jwt-bearer");
    const [header = "", claims = "", signature = ""] = (form.get("assertion") ?? "").split(".");
    expect(JSON.parse(Buffer.from(header, "base64url").toString())).toEqual({ alg: "RS256", typ: "JWT" });
    expect(JSON.parse(Buffer.from(claims, "base64url").toString())).toEqual({
      iss: CLIENT_EMAIL,
      scope: FCM_SCOPE,
      aud: TOKEN_URI,
      iat: 1_790_000_000,
      exp: 1_790_003_600,
    });
    const verified = await crypto.subtle.verify(
      "RSASSA-PKCS1-v1_5",
      publicKey,
      Buffer.from(signature, "base64url"),
      Buffer.from(`${header}.${claims}`),
    );
    expect(verified).toBe(true);
  });

  test("concurrent sends share one exchange", async () => {
    const responses = await Promise.all([send(VALID), send(VALID), send(VALID)]);
    expect(responses.map((response) => response.status)).toEqual([204, 204, 204]);
    expect(exchanges()).toHaveLength(1);
  });

  test("is refreshed 5 minutes before it expires", async () => {
    const start = 1_790_000_000_000;
    setSystemTime(new Date(start));
    await send(VALID);
    setSystemTime(new Date(start + (3599 - 300) * 1000 - 1));
    await send(VALID);
    expect(exchanges()).toHaveLength(1);
    setSystemTime(new Date(start + (3599 - 300) * 1000));
    await send(VALID);
    expect(exchanges()).toHaveLength(2);
    expect(new Headers(sends()[2]?.init?.headers).get("authorization")).toBe("Bearer access-2");
  });

  test("is fetched again after FCM answers 401", async () => {
    fcmReply = () => Response.json({ error: { code: 401, status: "UNAUTHENTICATED" } }, { status: 401 });
    expect((await send(VALID)).status).toBe(502);
    fcmReply = () => Response.json({ name: "projects/demo-project/messages/2" });
    expect((await send(VALID)).status).toBe(204);
    expect(exchanges()).toHaveLength(2);
  });
});

describe("rate limits", () => {
  test("30 sends a minute per FID, then 429 with Retry-After", async () => {
    setSystemTime(new Date(1_790_000_000_000));
    for (let i = 0; i < 30; i++) expect((await send(VALID, `203.0.113.${i}`)).status).toBe(204);
    const limited = await send(VALID, "203.0.113.200");
    expect(limited.status).toBe(429);
    expect(limited.headers.get("retry-after")).toBe("60");
    expect(sends()).toHaveLength(30);
    expect((await send({ ...VALID, fid: "fid-2" })).status).toBe(204);
    setSystemTime(new Date(1_790_000_060_000));
    expect((await send(VALID)).status).toBe(204);
  });

  test("60 requests a minute per address, valid or not, then 429", async () => {
    for (let i = 0; i < 60; i++) expect((await relay(post("{"), "198.51.100.1")).status).toBe(400);
    const limited = await relay(post("{"), "198.51.100.1");
    expect(limited.status).toBe(429);
    expect(Number(limited.headers.get("retry-after"))).toBeGreaterThan(0);
    expect((await relay(post("{"), "198.51.100.2")).status).toBe(400);
  });

  test("an IPv6 client rotating addresses within its /64 shares one address budget", async () => {
    for (let i = 0; i < 60; i++) expect((await relay(post("{"), `2001:db8:1:2::${i.toString(16)}`)).status).toBe(400);
    expect((await relay(post("{"), "2001:db8:1:2:aaaa:bbbb:cccc:dddd")).status).toBe(429);
    expect((await relay(post("{"), "2001:db8:1:3::1")).status).toBe(400);
  });
});
