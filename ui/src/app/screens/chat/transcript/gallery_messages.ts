// The `messages` scenario of the transcript gallery (gallery.tsx): a transcript holding every row kind of
// message_rows.tsx. Its first turn is settled work that folds under a summary row; the work rows that fold in a settled
// turn (thinking, an assistant image, a retried attempt, extension messages, a rules note) sit in the last turn, which
// shows every row while the session works.
import type { JsonObject } from "../../../../core/rpc/json_fields";
import {
  decodeMessage,
  modelChangeItem,
  rulesItem,
  thinkingChangeItem,
  type TranscriptItem,
} from "../../../../core/store/transcript";
import { base64Encode } from "../../../../core/util/base64";

const started = Date.UTC(2026, 9, 30, 8, 0);
const minute = 60_000;

type Rgb = readonly [number, number, number];

const crcTable = Array.from({ length: 256 }, (_, n) => {
  let c = n;
  for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1;
  return c >>> 0;
});

function crc32(bytes: Uint8Array): number {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = (crcTable[(crc ^ byte) & 0xff] ?? 0) ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

function chunk(type: string, data: Uint8Array): Uint8Array {
  const out = new Uint8Array(12 + data.length);
  const view = new DataView(out.buffer);
  view.setUint32(0, data.length);
  for (let i = 0; i < 4; i++) out[4 + i] = type.charCodeAt(i);
  out.set(data, 8);
  view.setUint32(8 + data.length, crc32(out.subarray(4, 8 + data.length)));
  return out;
}

/** A base64 PNG of `width`×`height` coloured by `color`, its pixels stored in uncompressed deflate blocks. */
function png(width: number, height: number, color: (x: number, y: number) => Rgb): string {
  const stride = 1 + width * 3;
  const raw = new Uint8Array(height * stride);
  for (let y = 0; y < height; y++) {
    for (let x = 0; x < width; x++) raw.set(color(x, y), y * stride + 1 + x * 3);
  }
  const blocks = Math.ceil(raw.length / 0xffff);
  const deflate = new Uint8Array(2 + blocks * 5 + raw.length + 4);
  const view = new DataView(deflate.buffer);
  deflate.set([0x78, 0x01]);
  let at = 2;
  for (let start = 0; start < raw.length; start += 0xffff) {
    const length = Math.min(0xffff, raw.length - start);
    deflate[at] = start + length === raw.length ? 1 : 0;
    view.setUint16(at + 1, length, true);
    view.setUint16(at + 3, ~length & 0xffff, true);
    deflate.set(raw.subarray(start, start + length), at + 5);
    at += 5 + length;
  }
  let a = 1;
  let b = 0;
  for (const byte of raw) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  view.setUint32(at, ((b << 16) | a) >>> 0);
  const header = new Uint8Array(13);
  new DataView(header.buffer).setUint32(0, width);
  new DataView(header.buffer).setUint32(4, height);
  header.set([8, 2], 8);
  const parts = [
    Uint8Array.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflate),
    chunk("IEND", new Uint8Array(0)),
  ];
  const file = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0));
  let offset = 0;
  for (const part of parts) {
    file.set(part, offset);
    offset += part.length;
  }
  return base64Encode(file);
}

/** What a client sees past the limit: a dark page with a card and a red band. */
function limitPage(x: number, y: number): Rgb {
  const card = x >= 40 && x < 280 && y >= 40 && y < 160;
  if (card && y < 52) return [224, 122, 118];
  if (card && y >= 72 && y < 80 && x < 200) return [143, 143, 143];
  if (card && y >= 92 && y < 98 && x < 240) return [92, 92, 92];
  return card ? [38, 38, 38] : [18, 18, 18];
}

const latencies = [22, 24, 25, 27, 29, 31, 34, 38, 39, 39, 40, 40];

/** p99 latency per load step, one bar each. */
function latencyChart(x: number, y: number): Rgb {
  const bar = Math.floor((x - 12) / 28);
  const value = latencies[bar];
  const inBar = x >= 12 && (x - 12) % 28 < 20 && value !== undefined;
  if (inBar && y >= 168 - value * 3.6) return bar >= 10 ? [214, 168, 92] : [125, 186, 138];
  return y === 168 ? [64, 64, 64] : [18, 18, 18];
}

const usage = (input: number, output: number, cost: number, extra: JsonObject = {}): JsonObject => ({
  input,
  output,
  cacheRead: Math.round(input * 0.8),
  totalTokens: input + output,
  cost: { total: cost },
  ...extra,
});

function assistant(at: number, content: JsonObject[], extra: JsonObject = {}): JsonObject {
  return {
    role: "assistant",
    content,
    provider: "fake",
    model: "think",
    stopReason: "stop",
    timestamp: at,
    ...extra,
  };
}

function toolCall(id: string, name: string, args: JsonObject): JsonObject {
  return { type: "toolCall", id, name, arguments: args };
}

function toolResult(at: number, id: string, name: string, text: string, details?: JsonObject): JsonObject {
  return { role: "toolResult", toolCallId: id, toolName: name, content: text, details, timestamp: at };
}

const bunTest = [
  "bun test v1.3.1",
  "",
  "src/routes/upload.test.ts:",
  "\u001b[32m✓\u001b[0m a bucket serves its burst \u001b[2m[0.57ms]\u001b[0m",
  "\u001b[32m✓\u001b[0m a bucket refills as time passes \u001b[2m[0.06ms]\u001b[0m",
  "\u001b[32m✓\u001b[0m past the limit, a 429 with Retry-After \u001b[2m[0.56ms]\u001b[0m",
  "",
  " \u001b[32m3 pass\u001b[0m",
  " 0 fail",
  "Ran 3 tests across 1 file. \u001b[2m[41.00ms]\u001b[0m",
].join("\n");

const reply = `## Token bucket

The bucket holds at most **60 tokens** and refills one a second, so a client can burst, then settles at the steady rate.

- \`allowance()\` takes a token or says how long to wait
- the wait is the time to the next token: $t = (1 - b) / r$ for a bucket at $b$ tokens refilling $r$ a second
- buckets idle for 10 minutes are dropped

| File | Change |
|---|---|
| \`src/lib/rate-limit.ts\` | token bucket per client, 60 a minute |
| \`src/routes/upload.ts\` | \`allowance()\` guard, 429 with \`Retry-After\` |

\`\`\`ts
const decision = allowance(request);
if (!decision.allowed) {
  return tooManyRequests(response, decision.retryAfterSeconds);
}
\`\`\`

$$
\\text{wait} = \\left\\lceil \\frac{1 - b}{r} \\right\\rceil
$$`;

const compaction = `## Goal
Rate limiting for the upload route.

## Done
- token bucket per client in \`src/lib/rate-limit.ts\`
- 429 with \`Retry-After\` in \`src/routes/upload.ts\`

<files>
# src/
lib/rate-limit.ts (RW)
routes/upload.ts (Write)
# test/
rate-limit.test.ts (Read)
[…2 files elided…]
</files>
`;

const stagingLog = [
  "Here is the log from staging:",
  ...Array.from({ length: 19 }, (_, i) => {
    const second = String(10 + i * 2).padStart(2, "0");
    return `2026-10-30T09:12:${second}Z upload 429 client=10.0.0.${40 + (i % 5)} wait=${12 - (i % 6)}s`;
  }),
].join("\n");

/** The gallery's transcript; see the file comment. */
export function messageGallery(): TranscriptItem[] {
  const t = (minutes: number, seconds = 0) => started + minutes * minute + seconds * 1000;
  const messages: (JsonObject | TranscriptItem)[] = [
    // A settled turn: its reads, edit and test run fold under "Worked for 1m 12s · 3 tool calls · 1 file edited".
    {
      role: "user",
      content:
        "Add rate limiting to the upload route: 60 requests a minute per client, and a 429 with Retry-After past that.",
      timestamp: t(0),
    },
    assistant(
      t(0, 2),
      [
        {
          type: "thinking",
          thinking:
            "The upload handler reads the body before anything checks the client. A token bucket per client fits.",
        },
        toolCall("call-read", "read", { path: "src/routes/upload.ts" }),
      ],
      { stopReason: "toolUse", usage: usage(6120, 210, 0.0021), duration: 2900 },
    ),
    toolResult(t(0, 5), "call-read", "read", 'import { Hono } from "hono";\n\nexport const app = new Hono();', {
      displayContent: { text: 'import { Hono } from "hono";\n\nexport const app = new Hono();', startLine: 1 },
      totalLines: 42,
    }),
    assistant(t(0, 6), [toolCall("call-edit", "edit", { path: "src/routes/upload.ts" })], {
      stopReason: "toolUse",
      usage: usage(6890, 340, 0.0024),
      duration: 9000,
    }),
    toolResult(t(0, 16), "call-edit", "edit", "Updated src/routes/upload.ts", {
      path: "src/routes/upload.ts",
      diff: [
        ' 12|app.post("/upload", async (c) => {',
        "+13|  const decision = allowance(c.req);",
        "+14|  if (!decision.allowed) return tooManyRequests(c, decision.retryAfterSeconds);",
        " 15|  const body = await c.req.parseBody();",
      ].join("\n"),
    }),
    assistant(t(0, 17), [toolCall("call-test", "bash", { command: "bun test src/routes" })], {
      stopReason: "toolUse",
      usage: usage(7210, 120, 0.0019),
      duration: 1800,
    }),
    toolResult(t(1, 0), "call-test", "bash", bunTest),
    assistant(
      t(1, 10),
      [
        {
          type: "text",
          text:
            "Done. The upload route takes a token before it reads the body; a client past 60 requests a minute gets " +
            "a 429 with `Retry-After`.",
        },
      ],
      { usage: usage(7512, 96, 0.0042), duration: 2400 },
    ),

    // File and model mentions, the files omp read for them, and a reply in every markdown block.
    {
      role: "user",
      content:
        'Compare @src/lib/rate-limit.ts with @"docs/rate limits.md" and @docs/diagram.png, and have ' +
        '<model agent="m1" name="Fake Think"/> check the bucket math. The numbers are in local://paste-1.md',
      timestamp: t(5),
    },
    {
      role: "fileMention",
      timestamp: t(5, 1),
      files: [
        { path: "src/lib/rate-limit.ts", lineCount: 84 },
        { path: "docs/rate limits.md", lineCount: 31 },
        { path: "docs/diagram.png", image: { type: "image", mimeType: "image/png" } },
      ],
    },
    assistant(t(5, 4), [{ type: "text", text: reply }], { usage: usage(12_480, 612, 0.0123), duration: 8400 }),

    // An image, then the user's own runs: a test run, Python kept out of the context, a cancelled and a failed one.
    {
      role: "user",
      content: [
        { type: "text", text: "This is what a client sees past the limit." },
        { type: "image", mimeType: "image/png", data: png(320, 200, limitPage) },
      ],
      timestamp: t(9),
    },
    assistant(
      t(9, 3),
      [{ type: "text", text: "That is the 429 page with `Retry-After: 12`; the client waits and retries on its own." }],
      { usage: usage(13_020, 41, 0.0061), duration: 1300 },
    ),
    { role: "bashExecution", command: "bun test src/routes", output: bunTest, exitCode: 0, timestamp: t(10) },
    {
      role: "pythonExecution",
      code: 'import json\nprint(json.dumps({"limit": 60, "window": "1m"}))',
      output: '{"limit": 60, "window": "1m"}\n',
      exitCode: 0,
      excludeFromContext: true,
      timestamp: t(10, 30),
    },
    {
      role: "bashExecution",
      command: "curl -sN localhost:8080/events",
      output: "data: tick\ndata: tick\n",
      cancelled: true,
      timestamp: t(11),
    },
    {
      role: "bashExecution",
      command: "bun run build",
      output:
        "src/routes/upload.ts:14:31 - error TS2345: Argument of type 'Request' is not assignable to parameter of " +
        "type 'Context'.\n\nFound 1 error in src/routes/upload.ts:14\n",
      exitCode: 2,
      truncated: true,
      timestamp: t(11, 30),
    },

    // A long paste folds to its first lines.
    { role: "user", content: stagingLog, timestamp: t(14) },
    assistant(
      t(14, 3),
      [{ type: "text", text: "Every 429 there came after a burst of 60; no client waited more than 12 s." }],
      { usage: usage(14_900, 38, 0.0068), duration: 1100 },
    ),

    // The context compacted; the model and thinking level changed.
    {
      role: "compactionSummary",
      summary: compaction,
      tokensBefore: 182_400,
      tokensAfter: 23_100,
      timestamp: t(20),
    },
    modelChangeItem({ key: "gallery-model", model: "fake/think" }),
    modelChangeItem({ key: "gallery-model-smol", model: "fake/fast", role: "smol" }),
    thinkingChangeItem({ key: "gallery-thinking", level: "high" }),

    // How replies end: an error, an interruption, the output token limit.
    { role: "user", content: "Run the load test against staging.", timestamp: t(21) },
    assistant(t(21, 2), [], {
      stopReason: "error",
      errorMessage: "529 Overloaded: the provider is busy, try again later.",
    }),
    { role: "user", content: "Try again with 500 clients.", timestamp: t(22) },
    assistant(t(22, 2), [{ type: "text", text: "Starting the run with 500 clients against staging…" }], {
      stopReason: "aborted",
      errorMessage: "Interrupted by user",
      usage: usage(15_300, 14, 0.0064),
    }),
    { role: "user", content: "Continue where you stopped.", synthetic: true, timestamp: t(23) },
    assistant(
      t(23, 2),
      [
        {
          type: "text",
          text:
            "The run with 500 clients finished. Up to 400 clients every request was served within 40 ms; from " +
            "there the",
        },
      ],
      { stopReason: "length", usage: usage(15_900, 4096, 0.0712), duration: 31_000 },
    ),

    // A branch the user left.
    {
      role: "branchSummary",
      summary:
        "Tried a sliding-window log instead of the bucket: it kept every request's time and grew with traffic, so " +
        "the branch was left.\n<read-files>\nsrc/lib/sliding-window.ts\n</read-files>\n",
      fromId: "e41",
      timestamp: t(25),
    },

    // The last turn: a message the agent sent, its work and its reply.
    {
      role: "user",
      content: "Check the p99 latency of the upload route under load.",
      attribution: "agent",
      timestamp: t(30),
    },
    assistant(t(30, 2), [], {
      stopReason: "error",
      errorMessage: "429 Too Many Requests",
      retryRecovery: { status: "recovered", attempt: 1 },
    }),
    assistant(
      t(30, 9),
      [
        { type: "redactedThinking", data: "gAAAAABnZ3Vlc3M=" },
        {
          type: "thinking",
          thinking:
            "Run the load script at rising client counts and read **p99** from its summary. Past 800 clients the " +
            "bucket should answer before the body is read, so latency should stay flat.",
        },
        toolCall("call-load", "bash", { command: "k6 run --summary-trend-stats=p(99) load.js" }),
      ],
      { stopReason: "toolUse", usage: usage(16_200, 520, 0.0081, { reasoningTokens: 342 }), duration: 6100 },
    ),
    toolResult(t(31, 40), "call-load", "bash", "http_req_duration p(99)=39.8ms\nhttp_reqs 48000\n"),
    rulesItem({ key: "gallery-rules", rules: ["no-sleep-in-tests", "prefer-bun-apis"] }),
    {
      role: "custom",
      customType: "async-result",
      content: "contract: 4 pass, 0 fail\ndocs: 2 pass, 0 fail",
      display: true,
      details: { jobs: [{ label: "contract" }, { label: "docs" }] },
      timestamp: t(32),
    },
    {
      role: "custom",
      customType: "live-delegation",
      content: "Check the bucket math in `src/lib/rate-limit.ts` against the numbers in the docs.",
      display: true,
      timestamp: t(32, 10),
    },
    {
      role: "hookMessage",
      customType: "lint-report",
      content: "**2 warnings** in `src/routes/upload.ts`: an unused import, a `let` that is never reassigned.",
      display: true,
      timestamp: t(32, 20),
    },
    {
      role: "custom",
      customType: "coverage",
      content: `Coverage of \`src/lib/rate-limit.ts\`: 96 % of lines.\n\n${Array.from(
        { length: 12 },
        (_, i) => `- line ${40 + i * 3}: covered by \`upload.test.ts\``,
      ).join("\n")}`,
      display: true,
      timestamp: t(32, 30),
    },
    assistant(
      t(33),
      [
        {
          type: "text",
          text:
            "p99 stays under 40 ms up to 800 clients; past that the bucket answers 429 before the body is read, so " +
            "latency stays flat.",
        },
        { type: "image", mimeType: "image/png", data: png(360, 180, latencyChart) },
      ],
      { usage: usage(17_400, 188, 0.0089), duration: 4600 },
    ),
  ];
  return messages.flatMap((message, index) =>
    isItem(message) ? [message] : (decodeMessage(message, { entryId: `gm${index}` }) ?? []),
  );
}

/** A note built by its factory, not a message to decode: messages carry no `kind`. */
function isItem(entry: JsonObject | TranscriptItem): entry is TranscriptItem {
  return typeof entry.kind === "string";
}
