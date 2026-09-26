import { strict as assert } from "node:assert";
import type { IncomingMessage, ServerResponse } from "node:http";
import { test } from "node:test";

import { TokenBucket, clientAddress, createRateLimiter, tooManyRequests } from "../src/lib/rate-limit.js";

function requestFrom(address: string | undefined): IncomingMessage {
  return { socket: address === undefined ? {} : { remoteAddress: address } } as IncomingMessage;
}

test("a bucket serves its burst, then reports the wait for the next token", () => {
  const bucket = new TokenBucket({ capacity: 3, refillPerSecond: 1, now: () => 0 });
  for (let i = 0; i < 3; i += 1) assert.equal(bucket.take("10.0.0.1").allowed, true);
  const denied = bucket.take("10.0.0.1");
  assert.equal(denied.allowed, false);
  assert.equal(denied.retryAfterSeconds, 1);
});

test("a bucket refills as time passes and keeps one bucket per client", () => {
  let now = 0;
  const bucket = new TokenBucket({ capacity: 1, refillPerSecond: 2, now: () => now });
  assert.equal(bucket.take("a").allowed, true);
  assert.equal(bucket.take("a").allowed, false);
  assert.equal(bucket.take("b").allowed, true, "another client has its own bucket");
  now = 500;
  assert.equal(bucket.take("a").allowed, true);
});

test("a request without a peer address shares one bucket instead of crashing", () => {
  const limiter = createRateLimiter({ capacity: 1, refillPerSecond: 1, now: () => 0 });
  assert.equal(clientAddress(requestFrom(undefined)), "unknown");
  assert.equal(limiter(requestFrom(undefined)).allowed, true);
  assert.equal(limiter(requestFrom(undefined)).allowed, false);
});

test("an over-limit client is answered with 429 and retry-after", () => {
  const limiter = createRateLimiter({ capacity: 1, refillPerSecond: 1, now: () => 0 });
  assert.equal(limiter(requestFrom("10.0.0.1")).allowed, true);
  const decision = limiter(requestFrom("10.0.0.1"));
  assert.equal(decision.allowed, false);

  const written: { status?: number; headers?: Record<string, string>; body?: string } = {};
  const response = {
    writeHead(status: number, headers: Record<string, string>) {
      written.status = status;
      written.headers = headers;
    },
    end(body: string) {
      written.body = body;
    },
  } as unknown as ServerResponse;
  tooManyRequests(response, decision.retryAfterSeconds);

  assert.equal(written.status, 429);
  assert.equal(written.headers?.["retry-after"], "1");
  assert.deepEqual(JSON.parse(written.body ?? "{}"), { error: "rate limit exceeded", retryAfterSeconds: 1 });
});
