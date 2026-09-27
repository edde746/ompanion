// POST /v1/send: one encrypted notification, handed to Firebase Cloud Messaging (docs/contracts/push.md, Relay).
// The relay keeps no state beyond the access token and the rate-limit counters, and never logs an FID or a body.

import { isRecord } from "./guards.ts";
import { clientKey, RateLimiter } from "./limiter.ts";
import { AccessTokens, UPSTREAM_TIMEOUT_MS, type ServiceAccount } from "./oauth.ts";

export type SendRequest = {
  fid: string;
  platform: "android" | "ios";
  nonce: string;
  ciphertext: string;
};

export type Relay = (request: Request, clientIp: string) => Promise<Response>;

const MAX_BODY_BYTES = 8 * 1024;
const MAX_FID_CHARS = 256;
const MAX_CIPHERTEXT_CHARS = 3072;
const TTL_SECONDS = 86_400;
const FIELDS: readonly string[] = ["fid", "platform", "nonce", "ciphertext"];
// 12 bytes are exactly 16 base64 characters, without padding.
const NONCE = /^[A-Za-z0-9+/]{16}$/;
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

// A machine sends one request per notification and device; a phone gets one per notification. Each limiter has
// its own 10,000 keys, so a flood of new addresses cannot crowd FIDs out, or the other way round.
const PER_IP_PER_MINUTE = 60;
const PER_FID_PER_MINUTE = 30;
const MAX_LIMITER_KEYS = 10_000;

const FCM_ERROR = "type.googleapis.com/google.firebase.fcm.v1.FcmError";
const BAD_REQUEST = "type.googleapis.com/google.rpc.BadRequest";

/** A response the handler ends with: thrown from anywhere below it. */
export class Reply extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly headers?: Record<string, string>,
  ) {
    super(message);
  }
}

/** Checks a decoded request body against the contract; throws a 400 Reply naming the first problem. */
export function validate(value: unknown): SendRequest {
  if (!isRecord(value)) throw new Reply(400, "the body is not a JSON object");
  for (const key of Object.keys(value)) {
    if (!FIELDS.includes(key)) throw new Reply(400, `unknown field ${JSON.stringify(key)}`);
  }
  for (const key of FIELDS) {
    if (!Object.hasOwn(value, key)) throw new Reply(400, `missing field "${key}"`);
  }
  const { fid, platform, nonce, ciphertext } = value;
  if (typeof fid !== "string" || fid === "" || fid.length > MAX_FID_CHARS) {
    throw new Reply(400, `fid must be a string of 1 to ${MAX_FID_CHARS} characters`);
  }
  if (platform !== "android" && platform !== "ios") throw new Reply(400, 'platform must be "android" or "ios"');
  if (typeof nonce !== "string" || !NONCE.test(nonce)) throw new Reply(400, "nonce must be the base64 of 12 bytes");
  if (typeof ciphertext !== "string" || ciphertext.length > MAX_CIPHERTEXT_CHARS) {
    throw new Reply(400, `ciphertext must be a string of at most ${MAX_CIPHERTEXT_CHARS} characters`);
  }
  if (ciphertext === "" || !BASE64.test(ciphertext)) throw new Reply(400, "ciphertext must be base64 with padding");
  return { fid, platform, nonce, ciphertext };
}

/** The FCM HTTP v1 request body for one notification; `now` in ms sets the APNs expiration. */
export function fcmMessage(send: SendRequest, now: number): { message: Record<string, unknown> } {
  const { fid, nonce: n, ciphertext: c } = send;
  if (send.platform === "android") {
    return { message: { fid, data: { v: "1", n, c }, android: { priority: "HIGH", ttl: `${TTL_SECONDS}s` } } };
  }
  return {
    message: {
      fid,
      apns: {
        headers: {
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-expiration": String(Math.floor(now / 1000) + TTL_SECONDS),
        },
        payload: {
          aps: { alert: { title: "ompanion", body: "Session update" }, "mutable-content": 1, sound: "default" },
          v: 1,
          n,
          c,
        },
      },
    },
  };
}

/**
 * The reply to an FCM error response (https://firebase.google.com/docs/reference/fcm/rest/v1/ErrorCode). Only an
 * FcmError detail says UNREGISTERED: a bare 404 NOT_FOUND can mean a wrong project, and must not delete phones.
 */
export function fcmErrorReply(status: number, body: unknown, retryAfter: string | null): Reply {
  const error = isRecord(body) && isRecord(body.error) ? body.error : {};
  const details = Array.isArray(error.details) ? error.details.filter(isRecord) : [];
  const detailCode = details.find((detail) => detail["@type"] === FCM_ERROR)?.errorCode;
  const code = typeof detailCode === "string" ? detailCode : typeof error.status === "string" ? error.status : "";
  const message = typeof error.message === "string" ? error.message : "";
  const text = `FCM ${status}${code ? ` ${code}` : ""}${message ? `: ${message}` : ""}`;
  if (code === "UNREGISTERED") return new Reply(410, text);
  if (code === "INVALID_ARGUMENT") {
    const namesFid = details.some(
      (detail) =>
        detail["@type"] === BAD_REQUEST &&
        Array.isArray(detail.fieldViolations) &&
        detail.fieldViolations.some((violation) => isRecord(violation) && violation.field === "message.fid"),
    );
    if (namesFid) return new Reply(410, text);
  }
  if (status === 429 || code === "QUOTA_EXCEEDED") {
    return new Reply(429, text, retryAfter ? { "retry-after": retryAfter } : undefined);
  }
  return new Reply(502, text);
}

async function readJson(request: Request): Promise<unknown> {
  const type = request.headers.get("content-type")?.split(";")[0]?.trim().toLowerCase();
  if (type !== "application/json") throw new Reply(400, "Content-Type must be application/json");
  const tooBig = new Reply(400, `the body is over ${MAX_BODY_BYTES} bytes`);
  if (Number(request.headers.get("content-length")) > MAX_BODY_BYTES) throw tooBig;
  // A chunked body has no Content-Length: stop reading it at the limit.
  const chunks: Uint8Array[] = [];
  let size = 0;
  for await (const chunk of request.body ?? []) {
    size += chunk.byteLength;
    if (size > MAX_BODY_BYTES) throw tooBig;
    chunks.push(chunk);
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks)));
  } catch (error) {
    throw new Reply(400, `the body is not UTF-8 JSON: ${String(error)}`);
  }
}

function limit(limiter: RateLimiter, key: string, what: string): void {
  const retryAfter = limiter.take(key, Date.now());
  if (retryAfter !== undefined) {
    throw new Reply(429, `rate limited: per-${what} limit`, { "retry-after": String(retryAfter) });
  }
}

/** The request handler, with its own access-token cache and rate limits. `fcmOrigin` is https://fcm.googleapis.com. */
export function createRelay(account: ServiceAccount, fcmOrigin: string): Relay {
  const accessTokens = new AccessTokens(account);
  const perIp = new RateLimiter(PER_IP_PER_MINUTE, 60_000, MAX_LIMITER_KEYS);
  const perFid = new RateLimiter(PER_FID_PER_MINUTE, 60_000, MAX_LIMITER_KEYS);
  const endpoint = `${fcmOrigin}/v1/projects/${encodeURIComponent(account.projectId)}/messages:send`;

  async function send(request: Request, clientIp: string): Promise<void> {
    limit(perIp, clientKey(clientIp), "address");
    const message = validate(await readJson(request));
    limit(perFid, message.fid, "FID");
    let accessToken: string;
    try {
      accessToken = await accessTokens.get();
    } catch (error) {
      throw new Reply(502, `OAuth: ${String(error)}`);
    }
    let response: Response;
    try {
      response = await fetch(endpoint, {
        method: "POST",
        headers: { authorization: `Bearer ${accessToken}`, "content-type": "application/json" },
        body: JSON.stringify(fcmMessage(message, Date.now())),
        signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS),
      });
    } catch (error) {
      throw new Reply(502, `FCM: ${String(error)}`);
    }
    if (response.ok) {
      await response.body?.cancel();
      return;
    }
    if (response.status === 401) accessTokens.drop(accessToken);
    const text = await response.text();
    let body: unknown = null;
    if (response.headers.get("content-type")?.includes("json")) {
      try {
        body = JSON.parse(text);
      } catch (error) {
        throw new Reply(502, `FCM ${response.status}: ${String(error)}`);
      }
    }
    throw fcmErrorReply(response.status, body, response.headers.get("retry-after"));
  }

  return async (request, clientIp) => {
    const { pathname } = new URL(request.url);
    if (pathname === "/healthz" && request.method === "GET") return new Response("ok\n");
    if (pathname !== "/v1/send") return Response.json({ error: "not found" }, { status: 404 });
    if (request.method !== "POST") {
      return Response.json({ error: "method not allowed" }, { status: 405, headers: { allow: "POST" } });
    }
    try {
      await send(request, clientIp);
      return new Response(null, { status: 204 });
    } catch (error) {
      if (!(error instanceof Reply)) throw error;
      return Response.json({ error: error.message }, { status: error.status, headers: error.headers });
    }
  };
}
