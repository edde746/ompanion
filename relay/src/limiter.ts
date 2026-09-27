import { isIPv6 } from "node:net";

/**
 * The rate-limit key for a client address. An IPv6 client holds a whole /64 and can send from any address in it,
 * so it counts as its /64; an IPv4-mapped IPv6 address (`::ffff:a.b.c.d`) counts as the IPv4 address. Anything
 * else, IPv4 included, is its own key.
 */
export function clientKey(address: string): string {
  const bare = address.replace(/%.*$/, "");
  if (!isIPv6(bare)) return address;
  // The URL parser writes the address canonically: lowercase hex, no leading zeros, no dotted IPv4 tail, and at
  // most one `::`.
  const [head = "", tail = ""] = new URL(`http://[${bare}]/`).hostname.slice(1, -1).split("::");
  const left = head ? head.split(":") : [];
  const right = tail ? tail.split(":") : [];
  const groups = [...left, ...Array<string>(8 - left.length - right.length).fill("0"), ...right];
  if (groups.slice(0, 6).join(":") === "0:0:0:0:0:ffff") {
    const [high = 0, low = 0] = groups.slice(6).map((group) => parseInt(group, 16));
    return `${high >> 8}.${high & 255}.${low >> 8}.${low & 255}`;
  }
  return `${groups.slice(0, 4).join(":")}::/64`;
}

/**
 * Fixed-window request counters per key, holding at most `maxKeys` keys. A key whose window has ended makes room
 * for a new one; while every window is still open, a new key is turned away rather than an open window dropped,
 * so a flood of new keys cannot reset anyone's count.
 */
export class RateLimiter {
  // Map iteration follows insertion order, and a key is deleted and set again when its window restarts, so the
  // oldest windows come first: clearing ended windows stops at the first one still open.
  readonly #windows = new Map<string, { start: number; count: number }>();

  constructor(
    private readonly limit: number,
    private readonly windowMs: number,
    private readonly maxKeys: number,
  ) {}

  get size(): number {
    return this.#windows.size;
  }

  /** Counts a request for `key` at `now` (ms): undefined when allowed, else the seconds to wait. */
  take(key: string, now: number): number | undefined {
    let window = this.#windows.get(key);
    if (window && now - window.start >= this.windowMs) {
      this.#windows.delete(key);
      window = undefined;
    }
    if (!window) {
      for (const [oldKey, old] of this.#windows) {
        if (now - old.start < this.windowMs) break;
        this.#windows.delete(oldKey);
      }
      const oldest = this.#windows.values().next().value;
      if (oldest && this.#windows.size >= this.maxKeys) return Math.ceil((oldest.start + this.windowMs - now) / 1000);
      window = { start: now, count: 0 };
      this.#windows.set(key, window);
    }
    if (window.count >= this.limit) return Math.ceil((window.start + this.windowMs - now) / 1000);
    window.count++;
    return undefined;
  }
}
