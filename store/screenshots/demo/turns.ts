/**
 * The scripted model turns behind the store screenshots.
 *
 * The app runs one real omp session per machine against the fake provider (`harness/fake-provider`), and this
 * script plays the model: it queues turns on the provider's control API while the app drives the session, so
 * the transcript shows a real task with real tool cards, a real diff, a subagent and a real test run.
 *
 *   bun store/screenshots/demo/turns.ts --provider http://127.0.0.1:18991 --session hero
 *   bun store/screenshots/demo/turns.ts --provider http://127.0.0.1:18991 --session deploy
 *
 * `hero` works in `~/code/api-server` (rate limiting for the upload route); `deploy` works in
 * `~/work/pipeline`, whose project config asks for tool approval, so its cards wait for a tap.
 *
 * Every parent turn carries `match: <phrase of the user prompt>` and every subagent turn
 * `match: '"name":"yield"'`, the routing the fake provider documents: only subagents are offered `yield`.
 * The two sessions run at the same time against one provider and never steal each other's turns.
 *
 * The hashline `edit` must quote the snapshot tag omp minted during the `read`, so the first turn is queued
 * with a `wait` behind it and the rest goes in as soon as the tag shows up in a request body.
 *
 * `store/screenshots/capture.sh` starts this; `store/screenshots/README.md` has the manual recipe.
 */

const PROVIDER = argOf("--provider") ?? "http://127.0.0.1:18991";
/** Text the finished patch adds to the read file; seeing it in a read means a previous run already ran. */
const DIRTY_MARK: Record<string, string | undefined> = { hero: "rate-limit.js", deploy: "token_file" };

const SESSION = argOf("--session") ?? "hero";

/** The prompts the capture harness types into the composer; every turn matches on them. */
export const PROMPTS = {
  hero: "Add rate limiting to the upload endpoint so one client cannot exhaust the put path, then run the tests.",
  ask: "Document the limit in the README, and ask me for the numbers you should write down.",
  deploy: "Rotate the deploy token in deploy.sh and smoke-test the staging deploy.",
} as const;

type Step =
  | { text: string }
  | { thinking: string }
  | { toolCall: { name: string; arguments: Record<string, unknown> } }
  | { delayMs: number };

interface Turn {
  steps: Step[];
  match?: string;
  wait?: true;
  usage?: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
}

const call = (name: string, args: Record<string, unknown>): Step => ({ toolCall: { name, arguments: args } });

/** One text step per line, a frame apart, so the app renders the answer while it streams. */
function lines(text: string, delayMs = 25): Step[] {
  return text.split(/(?<=\n)/).flatMap((line, index): Step[] => (index === 0 ? [{ text: line }] : [{ delayMs }, { text: line }]));
}

const RATE_LIMIT_MODULE = `import type { IncomingMessage, ServerResponse } from "node:http";

export interface Decision {
  allowed: boolean;
  /** Whole seconds until this client may retry; 0 when the request was allowed. */
  retryAfterSeconds: number;
}

export interface TokenBucketOptions {
  /** Requests a client may make back to back. */
  capacity: number;
  /** Tokens added back per second. */
  refillPerSecond: number;
  /** Injectable clock in milliseconds, for tests. */
  now?: () => number;
}

interface Bucket {
  tokens: number;
  updatedAt: number;
}

/**
 * One token bucket per client: a client may burst to \\\`capacity\\\` and refills at \\\`refillPerSecond\\\`.
 * Buckets refill lazily, so an idle client costs nothing.
 */
export class TokenBucket {
  readonly #capacity: number;
  readonly #refillPerSecond: number;
  readonly #now: () => number;
  readonly #buckets = new Map<string, Bucket>();

  constructor(options: TokenBucketOptions) {
    if (!(options.capacity >= 1)) throw new Error("capacity must be at least 1, got " + options.capacity);
    if (!(options.refillPerSecond > 0)) throw new Error("refillPerSecond must be positive, got " + options.refillPerSecond);
    this.#capacity = options.capacity;
    this.#refillPerSecond = options.refillPerSecond;
    this.#now = options.now ?? Date.now;
  }

  take(key: string): Decision {
    const now = this.#now();
    const bucket = this.#buckets.get(key) ?? { tokens: this.#capacity, updatedAt: now };
    const tokens = Math.min(this.#capacity, bucket.tokens + ((now - bucket.updatedAt) / 1000) * this.#refillPerSecond);
    this.#buckets.set(key, { tokens, updatedAt: now });
    if (tokens < 1) {
      const wait = Math.ceil((1 - tokens) / this.#refillPerSecond);
      return { allowed: false, retryAfterSeconds: Math.max(1, wait) };
    }
    this.#buckets.set(key, { tokens: tokens - 1, updatedAt: now });
    return { allowed: true, retryAfterSeconds: 0 };
  }
}

/** A limiter keyed by the peer address of each request. */
export function createRateLimiter(options: TokenBucketOptions): (request: IncomingMessage) => Decision {
  const buckets = new TokenBucket(options);
  return (request) => buckets.take(clientAddress(request));
}

/** The bucket key of a request; requests without a peer address share one bucket. */
export function clientAddress(request: IncomingMessage): string {
  const address = request.socket?.remoteAddress;
  return address === undefined || address === "" ? "unknown" : address;
}

/** 60 uploads a minute per client, bursting to 60. */
const defaultLimiter = createRateLimiter({ capacity: 60, refillPerSecond: 1 });

export function allowance(request: IncomingMessage): Decision {
  return defaultLimiter(request);
}

/** Answers 429 with the \\\`Retry-After\\\` header the client should honour. */
export function tooManyRequests(response: ServerResponse, retryAfterSeconds: number): void {
  response.writeHead(429, { "content-type": "application/json", "retry-after": String(retryAfterSeconds) });
  response.end(JSON.stringify({ error: "rate limit exceeded", retryAfterSeconds }));
}
`;

const HERO_ANSWER = `Done. The upload route spends a token before it reads the body.

| File | Change |
| --- | --- |
| \`src/lib/rate-limit.ts\` | token bucket per client, 60 a minute |
| \`src/routes/upload.ts\` | \`allowance()\` guard, \`429\` with \`Retry-After\` |

\`\`\`ts
const decision = allowance(request);
if (!decision.allowed) {
  tooManyRequests(response, decision.retryAfterSeconds);
  return;
}
\`\`\`
`;

const DEPLOY_EDIT = `[deploy.sh#TAG]
PUT 8.=8:
+token_file=\${DEPLOY_TOKEN_FILE:-$HOME/.config/deploy/token}
+[ -r "$token_file" ] || { echo "no deploy token at $token_file" >&2; exit 1; }
+token=$(cat "$token_file")
`;

const ASK_TURN: Turn = {
  match: PROMPTS.ask,
  steps: [
    { thinking: "The README documents the endpoints but not the limit. The numbers are a product call, so I ask." },
    { text: "The README has no rate-limit row yet. Two numbers go into it, and both are your call." },
    call("ask", {
      i: "Asking which rate limit to document",
      questions: [
        {
          id: "limit",
          header: "Rate limit",
          question: "Which limit should the README document for POST /upload?",
          options: [
            { label: "60 requests a minute per client", description: "The default the limiter ships with" },
            { label: "600 requests a minute per client", description: "Generous; bursts to 600" },
            { label: "Set it from UPLOAD_MAX_RATE", description: "Read the limit from the environment" },
          ],
          recommended: 0,
        },
        {
          id: "retry",
          header: "Retry-After",
          question: "Should the README document the Retry-After header the route answers with?",
          options: [
            { label: "Yes, with an example response", description: "429 plus the header" },
            { label: "Just mention it in the table", description: "One line in the endpoint table" },
          ],
          recommended: 0,
        },
      ],
    }),
  ],
};

const HERO_BEFORE_EDIT: Turn[] = [
  {
    match: PROMPTS.hero,
    steps: [
      {
        thinking:
          "Two files: a limiter module and the route that calls it. The test file already pins the contract, so read the route first and let the test decide the shape.",
      },
      { text: "Reading the upload route before touching it." },
      call("read", { i: "Reading the upload route", path: "src/routes/upload.ts" }),
    ],
  },
  { match: PROMPTS.hero, wait: true },
];

function heroAfterEdit(tag: string): Turn[] {
  return [
    {
      match: PROMPTS.hero,
      steps: [
        { text: "Planning the change." },
        call("todo", {
          i: "Planning the rate limit work",
          op: "init",
          list: [
            { phase: "Plan", items: ["Read the upload route", "Read the test that pins the limiter"] },
            { phase: "Implement", items: ["Add the rate-limit module", "Wire the upload route"] },
            { phase: "Verify", items: ["Run the type check and the tests"] },
          ],
        }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "The route is a buffer-and-store; the limiter belongs in front of the read." },
        call("todo", { i: "Finished reading the route", op: "done", task: "Read the upload route" }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "Handing three things to subagents: the limiter contract, the README wording and the test names." },
        call("task", {
          i: "Delegating the contract, the docs and the tests",
          context: "Store screenshot session in ~/code/api-server; the upload route is being given a rate limit.",
          tasks: [
            {
              name: "contract",
              task: "Read test/rate-limit.test.ts and report the exact contract it expects from src/lib/rate-limit.ts: exported names, option names, return shape and edge cases. Reply with the report only.",
            },
            {
              name: "docs",
              task: "Read README.md and report the rows its endpoint table is missing once POST /upload answers 429 with Retry-After. Reply with the rows only.",
            },
            {
              name: "tests",
              task: "Read src/routes/upload.ts and list the cases its guard does not cover yet. Reply with the list only.",
            },
          ],
        }),
      ],
    },
    {
      match: '"name":"yield"',
      steps: [
        { text: "Reading the test that pins the limiter." },
        call("read", { i: "Reading the rate-limit test", path: "test/rate-limit.test.ts" }),
      ],
    },
    {
      match: '"name":"yield"',
      steps: [
        call("yield", {
          data: {
            module: "src/lib/rate-limit.ts",
            exports: ["TokenBucket", "createRateLimiter", "clientAddress", "allowance", "tooManyRequests"],
            options: "TokenBucketOptions { capacity, refillPerSecond, now? }",
            decision: "Decision { allowed, retryAfterSeconds }",
            edges: ["a burst of capacity is allowed", "the next request reports retryAfterSeconds", "buckets are per client", "a request without a peer address uses the key 'unknown'"],
          },
        }),
      ],
    },
    {
      match: '"name":"yield"',
      steps: [
        { text: "Checking the README's endpoint table." },
        call("read", { i: "Reading the README", path: "README.md" }),
      ],
    },
    {
      match: '"name":"yield"',
      steps: [
        call("yield", {
          data: {
            missing_rows: ["| `/upload` | POST | `429` when the client is over its rate limit |"],
            note: "the table already documents 201 and 413",
          },
        }),
      ],
    },
    {
      match: '"name":"yield"',
      steps: [
        { text: "Listing the uncovered cases." },
        call("read", { i: "Reading the upload route", path: "src/routes/upload.ts" }),
      ],
    },
    {
      match: '"name":"yield"',
      steps: [
        call("yield", {
          data: {
            uncovered: ["a client that refills between bursts", "two clients sharing one address behind a proxy", "the guard's answer when the body is already too large"],
          },
        }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "The contract is clear: a token bucket per client, `allowance` for the route, `tooManyRequests` for the answer." },
        call("todo", { i: "Contract agreed with the subagent", op: "done", task: "Read the test that pins the limiter" }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "Adding the limiter module." },
        call("write", { path: "src/lib/rate-limit.ts", content: RATE_LIMIT_MODULE }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "The module is in." },
        call("todo", { i: "Module written", op: "done", task: "Add the rate-limit module" }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "Wiring the route: one import, and a guard before the body is read." },
        call("edit", {
          i: "Wiring the rate limiter into the upload route",
          input: `[src/routes/upload.ts#${tag}]
PUT <5:
+import { allowance, clientAddress, tooManyRequests } from "../lib/rate-limit.js";
PUT >16:
+  const decision = allowance(request);
+  if (!decision.allowed) {
+    logger.warn("upload rate limited", { client: clientAddress(request) });
+    tooManyRequests(response, decision.retryAfterSeconds);
+    return;
+  }
`,
        }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "The guard is in place." },
        call("todo", { i: "Route wired", op: "done", task: "Wire the upload route" }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "Module and route are wired; running the suite." },
        call("bash", { i: "Running the tests", command: "npm test" }),
      ],
    },
    {
      match: PROMPTS.hero,
      steps: [
        { text: "Green. Writing the summary." },
        call("todo", { i: "Suite is green", op: "done", task: "Run the type check and the tests" }),
      ],
    },
    { match: PROMPTS.hero, steps: lines(HERO_ANSWER) },
    // One long answer the machine list can show as a session that is still working while the sidebar is
    // photographed: the last prompt waits behind this slow turn rather than finishing in a second.
    {
      match: "Run the long check",
      steps: [
        { text: "Starting the long check.\n" },
        ...Array.from({ length: 24 }, (_, index): Step[] => [
          { delayMs: 2500 },
          { text: `Step ${index + 1} of 24 of the long check: the session stays busy while the machine list is read.\n` },
        ]).flat(),
      ],
    },
    // omp reminds a session that stops with open tasks; answer it in words rather than letting the provider's
    // default "ok" land in the transcript.
    { match: "incomplete todo item", steps: lines("Every item in the plan is done; nothing is left open.\n") },
    ASK_TURN,
  ];
}

const DEPLOY_BEFORE_EDIT: Turn[] = [
  {
    match: PROMPTS.deploy,
    steps: [
      {
        thinking:
          "The token sits in a default in deploy.sh; a deployment should refuse to run without a real one. Read the script, then change the one line that resolves it.",
      },
      { text: "Reading the deploy script." },
      call("read", { i: "Reading the deploy script", path: "deploy.sh" }),
    ],
  },
  { match: PROMPTS.deploy, wait: true },
];

function deployAfterEdit(tag: string): Turn[] {
  return [
    {
      match: PROMPTS.deploy,
      steps: [
        { text: "Rotating the token: read it from a file and fail loudly when it is missing." },
        call("edit", { i: "Reading the deploy token from a file", input: DEPLOY_EDIT.replace("#TAG", `#${tag}`) }),
      ],
    },
    {
      match: PROMPTS.deploy,
      steps: [
        { text: "Now the smoke test against staging." },
        call("bash", { i: "Smoke-testing the staging deploy", command: "sh scripts/smoke.sh" }),
      ],
    },
    { match: PROMPTS.deploy, steps: lines("The smoke test passed once the token was read from the file.") },
  ];
}

/** Queues the turns of one session; waits for the prompts the app sends, one model call at a time. */
async function run(): Promise<void> {
  const prompt = SESSION === "deploy" ? PROMPTS.deploy : PROMPTS.hero;
  const before = SESSION === "deploy" ? DEPLOY_BEFORE_EDIT : HERO_BEFORE_EDIT;
  if (SESSION === "hero") await reset();

  await enqueue(before);
  const path = SESSION === "deploy" ? "deploy.sh" : "src/routes/upload.ts";
  const tag = await waitForTag(path);
  const after = SESSION === "deploy" ? deployAfterEdit(tag) : heroAfterEdit(tag);
  await enqueue(after);
  log(`queued ${String(before.length + after.length)} turns for "${prompt.slice(0, 40)}…" (tag ${tag})`);

  // Drain: the last model call of the session is answered, and no request has arrived since.
  let idle = 0;
  let seen = (await requests()).length;
  while (idle < 6) {
    await Bun.sleep(2000);
    const now = (await requests()).length;
    if (now === seen) idle += 1;
    else {
      idle = 0;
      seen = now;
    }
  }
  log(`session done after ${String(seen)} model requests`);
}

/** The tool result of a `read` of [path] in a request body, or undefined when this body has none. */
function readResultOf(body: unknown, path: string): string | undefined {
  const messages = (body as { messages?: unknown }).messages;
  if (!Array.isArray(messages)) return undefined;
  for (const message of messages) {
    const content = JSON.stringify((message as { content?: unknown }).content ?? "");
    if (content.includes(`[${path}#`)) return content;
  }
  return undefined;
}

/** Waits for the read result of [path] and returns the 4-hex snapshot tag omp minted for it. */
async function waitForTag(path: string): Promise<string> {
  const pattern = new RegExp(`\\[${path.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}#([0-9A-Fa-f]{4})\\]`);
  for (let attempt = 0; attempt < 300; attempt += 1) {
    for (const request of await requests()) {
      const tag = pattern.exec(JSON.stringify(request.body))?.[1];
      if (tag === undefined) continue;
      // The patch inserts lines at fixed numbers, so a project a previous run already edited would double
      // them. Only the read result counts here: the request body also carries omp's system prompt, which
      // mentions the test file by name.
      const dirty = DIRTY_MARK[SESSION];
      const read = readResultOf(request.body, path);
      if (dirty !== undefined && read !== undefined && read.includes(dirty)) {
        throw new Error(`${path} already carries "${dirty}": the demo project is dirty, re-seed the host`);
      }
      return tag;
    }
    await Bun.sleep(1000);
  }
  throw new Error(`no hashline tag for ${path} arrived; is the app on the read turn?`);
}

async function reset(): Promise<void> {
  await fetch(`${PROVIDER}/control/reset`, { method: "POST" });
}

async function enqueue(turns: Turn[]): Promise<void> {
  const response = await fetch(`${PROVIDER}/control/enqueue`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(turns),
  });
  if (!response.ok) throw new Error(`enqueue failed: ${response.status} ${await response.text()}`);
}

interface LoggedRequest {
  body: unknown;
}

async function requests(): Promise<LoggedRequest[]> {
  const response = await fetch(`${PROVIDER}/control/requests`);
  if (!response.ok) throw new Error(`requests failed: ${response.status}`);
  return (await response.json()) as LoggedRequest[];
}

function log(message: string): void {
  process.stderr.write(`turns[${SESSION}]: ${message}\n`);
}

function argOf(flag: string): string | undefined {
  const index = process.argv.indexOf(flag);
  return index === -1 ? undefined : process.argv[index + 1];
}

if (import.meta.main) await run();
