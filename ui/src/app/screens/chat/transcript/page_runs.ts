// Which agent pages (the companion's html_render) were loading when the app last stopped. A busy page in its frame
// stops the app page's scripts on WKWebView and Android WebView, until the app is killed, and opening the session
// again would run it again. So every frame records its page in localStorage before the page runs and ends the record
// a second after the page has loaded, or when the frame goes first: a page that hangs while it loads, or right after,
// keeps its record. A record still there when a page is about to run was left by an app that stopped during that
// time (frozen and killed, reloaded by its shell, or quit): that page waits for the reader to run it, and its record
// stays until a run of it ends.

/** Prefix of a record's localStorage key; the rest is the page's `pageKey`. */
const prefix = "ompanion.page-running.";

/** What `PageRuns` needs of `localStorage`. */
export type RunStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

/**
 * A page's key: a 53-bit hash of its HTML (cyrb53) in hex, so the same page anywhere (the row, full screen, another
 * session) shares one record.
 */
export function pageKey(html: string): string {
  let h1 = 0xdeadbeef;
  let h2 = 0x41c6ce57;
  for (let index = 0; index < html.length; index++) {
    const code = html.charCodeAt(index);
    h1 = Math.imul(h1 ^ code, 2654435761);
    h2 = Math.imul(h2 ^ code, 1597334677);
  }
  h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909);
  h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909);
  return (4294967296 * (2097151 & h2) + (h1 >>> 0)).toString(16);
}

/** The records of the pages this app runs, and of the ones a stopped app left. */
export class PageRuns {
  /** The frames of this app that run each page, by key. */
  private readonly live = new Map<string, number>();

  constructor(private readonly storage: RunStorage) {}

  /**
   * Whether the page `key` was loading when the app last stopped: its record is still there, and no frame of this
   * app runs it.
   */
  stoppedLastTime(key: string): boolean {
    return !this.live.has(key) && this.storage.getItem(prefix + key) !== null;
  }

  /**
   * Records the page `key` as running, before its frame gets it; the returned function ends that frame's run, once
   * however often it is called (after the page loaded, and when the frame goes). The record goes with the last run.
   */
  start(key: string): () => void {
    this.live.set(key, (this.live.get(key) ?? 0) + 1);
    this.storage.setItem(prefix + key, "1");
    let ended = false;
    return () => {
      if (ended) return;
      ended = true;
      const frames = this.live.get(key) ?? 0;
      if (frames > 1) {
        this.live.set(key, frames - 1);
        return;
      }
      this.live.delete(key);
      this.storage.removeItem(prefix + key);
    };
  }
}
