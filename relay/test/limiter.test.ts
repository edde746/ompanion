import { expect, test } from "bun:test";
import { clientKey, RateLimiter } from "../src/limiter.ts";

test("allows `limit` requests per window, then says how long to wait", () => {
  const limiter = new RateLimiter(2, 60_000, 100);
  expect(limiter.take("a", 0)).toBeUndefined();
  expect(limiter.take("a", 1_000)).toBeUndefined();
  expect(limiter.take("a", 1_500)).toBe(59);
  expect(limiter.take("b", 1_500)).toBeUndefined();
  expect(limiter.take("a", 60_000)).toBeUndefined();
});

test("ended windows make room for new keys; while every window is open, new keys wait instead", () => {
  const limiter = new RateLimiter(1, 60_000, 3);
  limiter.take("old", 0);
  limiter.take("a", 30_000);
  limiter.take("b", 30_000);
  // "old"'s window has ended: it goes, and the open windows stay.
  expect(limiter.take("c", 61_000)).toBeUndefined();
  expect(limiter.size).toBe(3);

  // Full of open windows: a new key waits for the oldest ("a") to end, and every open window keeps its count.
  expect(limiter.take("d", 62_000)).toBe(28);
  for (let i = 0; i < 1_000; i++) expect(limiter.take(`k${i}`, 63_000)).toBe(27);
  expect(limiter.size).toBe(3);
  expect(limiter.take("a", 63_000)).toBe(27);
  expect(limiter.take("b", 63_000)).toBe(27);
  expect(limiter.take("c", 63_000)).toBe(58);

  // "a" and "b" end at 90 s and make room.
  expect(limiter.take("d", 90_000)).toBeUndefined();
  expect(limiter.size).toBe(2);
});

test("an IPv6 client is its /64, an IPv4-mapped address its IPv4 address, IPv4 itself", () => {
  const net = "2001:db8:1:2::/64";
  expect(clientKey("2001:db8:1:2:3:4:5:6")).toBe(net);
  expect(clientKey("2001:0DB8:0001:0002:ffff::1")).toBe(net);
  expect(clientKey("2001:db8:1:2::")).toBe(net);
  expect(clientKey("2001:db8:1:3::1")).toBe("2001:db8:1:3::/64");
  expect(clientKey("2001:db8::1")).toBe("2001:db8:0:0::/64");
  expect(clientKey("fe80::1%eth0")).toBe("fe80:0:0:0::/64");
  expect(clientKey("::ffff:203.0.113.9")).toBe("203.0.113.9");
  expect(clientKey("::ffff:cb00:7109")).toBe("203.0.113.9");
  expect(clientKey("203.0.113.9")).toBe("203.0.113.9");
  expect(clientKey("203.0.113.10")).toBe("203.0.113.10");
});
