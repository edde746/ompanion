# harness

A deterministic model backend for real omp processes: a fake OpenAI-compatible provider, isolated omp
homes that point at it, and RPC fixtures recorded from omp 18.3.1. No test here reaches a paid
provider. `sshd/` (SSH test containers) is documented separately.

| Path | Contents |
|---|---|
| `fake-provider/server.ts` | the provider: scripted turns in, OpenAI chat-completions SSE out |
| `fake-provider/client.ts` | `FakeProvider`: starts the server as a child process, drives its control API |
| `fake-provider/demo.ts` | `--demo`: canned turns for running the app without a model |
| `omp-home.sh`, `omp-home.ts` | isolated omp home (shell and Bun), environment for omp children |
| `dev-machine.sh` | a local dev machine for the app: omp home, `<home>/.local/bin/omp`, demo project |
| `record.ts` | records a scenario from a real omp into `fixtures/` |
| `fixtures/` | `<scenario>.out.jsonl` (omp stdout) and `<scenario>.in.jsonl` (lines sent) |

Typecheck: `companion/node_modules/.bin/tsc -p harness` (borrows the companion's Bun types).

## Fake provider

```sh
bun harness/fake-provider/server.ts --port 0           # first stdout line: listening <port>
bun harness/fake-provider/server.ts --port 0 --demo    # unscripted requests get the demo rotation
```

It listens on 127.0.0.1; `--host <address>` picks another address. The Docker session tests on Linux
pass the host gateway's, where the SSH test machines reach this computer as `host.docker.internal`.

| Route | Purpose |
|---|---|
| `POST /v1/chat/completions` | answers with the next eligible queued turn; SSE when `stream: true`, JSON otherwise |
| `GET /v1/models` | lists `fake-1`, `fake-think` |
| `POST /control/enqueue` | appends one turn or an array of turns |
| `POST /control/reset` | clears the queue and the request log |
| `GET /control/requests` | every completions request: `{path, body, served: "queue" \| "default" \| "demo", demo?}` |
| `GET /control/health` | `{ok, queued, requests}` |

A turn answers one model request:

```ts
type Turn =
  | { steps: Step[]; finish?: "stop" | "tool_calls" | "length"; usage?: Usage; match?: string }
  | { error: { status: number; message?: string; headers?: Record<string, string> }; match?: string }
  | { wait: true; match?: string };
type Step =
  | { text: string }            // delta.content
  | { thinking: string }        // delta.reasoning_content
  | { toolCall: { id?: string; name: string; arguments: object } }  // delta.tool_calls, arguments in two halves
  | { delayMs: number }
  | { hang: true };             // keep the stream open until the client disconnects
```

- Requests take the first queued turn they are eligible for. A turn with `match` only answers a request
  whose raw JSON body contains that text. `'"name":"yield"'` selects subagent requests: only
  subagents are offered the `yield` tool.
- `wait` parks the request until another eligible turn is enqueued, which then answers it. Use it when
  the model's output depends on what omp did first, e.g. quoting the hashline tag a `read` returned.
- With nothing eligible queued the server answers `ok`, so side calls never hang; `served: "default"`
  in the request log shows it. With `--demo` the demo rotation answers instead (see Dev machine).
- omp's session title requests (the ompanion companion turns omp's automatic titles on in RPC) race the
  conversation, so only a turn whose `match` they contain answers one: match `Write a ~5 word title`, the first
  line of omp's title prompt. Otherwise the server declines (`<title/>`) and the session stays untitled. They
  are left out of the request log.
- `finish` defaults to `tool_calls` when a step calls a tool, else `stop`. `usage` defaults to
  characters / 4 for the request messages and the output; it is sent when the request asks for
  `stream_options.include_usage`, which omp does.
- Tool ids default to `call_<request number>_<index>`.

Bun tests:

```ts
import { FakeProvider } from "../harness/fake-provider/client.ts";
import { createOmpHome, ompEnv } from "../harness/omp-home.ts";

const fake = await FakeProvider.start();          // fake.port, fake.baseUrl
await createOmpHome(home, fake.port);             // optional third argument: extra config YAML
await fake.enqueue([{ steps: [{ text: "hi" }] }]);
Bun.spawn([omp, "--mode", "rpc-ui", "--model", "fake/fake-1"], { cwd, env: ompEnv(home), ... });
const sent = await fake.requests();               // also: fake.health(), fake.reset()
await fake.stop();
```

What omp 18.3.1 does with scripted output:

- Every built-in tool requires the string argument `i` (intent), e.g.
  `{name: "bash", arguments: {i: "Printing hi", command: "echo hi"}}`. `yield` takes none.
- An HTTP 500 is retried inside one model call: 6 transport attempts, then the whole call once more.
  The session sees the error only after 12 failing requests, then auto-retries (`error-retry`). The
  transport retries 408, 429 and other 5xx the same way. A `retry-after-ms: 0` header skips its
  backoff.
- A stream that repeats an exact cycle (the same line many times) is aborted as "Thinking loop
  detected" and retried. Long generated text needs varying lines, e.g. numbered ones.
- The session file keeps at most 500,000 characters per string; longer text comes back truncated
  after a resume.

## Isolated omp home

```sh
harness/omp-home.sh <home-dir> <port> [extra-config.yml]
```

Writes `<home-dir>/.omp/agent/models.yml` (provider `fake` at `http://127.0.0.1:<port>/v1`, models
`fake-1` and `fake-think` (`reasoning: true`), both with a 128000-token context) and
`<home-dir>/.omp/agent/config.yml`. Prints nothing on success. A top-level key in the extra file
replaces the same key of the base config wholesale; other keys are added.

| Base setting | Why |
|---|---|
| `startup.checkUpdate: false` | no release check over the network |
| `marketplace.autoUpdate: "off"` | no plugin update check |
| `power.sleepPrevention: "off"` | no sleep assertion on the host |
| `lsp.enabled: false` | no language servers started by tests |
| `ttsr.enabled: false` | no stream rules interrupting scripted output |
| `dev.autoqa: false` | no issue-reporting tool note in the system prompt |

RPC mode itself turns off title generation, the advisor and memory.

Run omp with `HOME=<home-dir>` and nothing else from the caller's environment that omp reads:
`ompEnv(home)` passes only `PATH`, `TMPDIR`, `USER`, `SHELL` and `LANG`, so `PI_*`/`XDG_*` overrides
and provider API keys never reach omp. Launch with `--model fake/fake-1` (or `fake/fake-think`) and a
working directory outside the repository. A fresh home grows to ~160 MB (omp unpacks its natives) and
omp needs ~2.4 s to `ready`; delete the home afterwards.

## Dev machine

A local machine for running the app without a model: the demo provider plus an isolated home with the
pinned omp.

```sh
bun harness/fake-provider/server.ts --port 18999 --demo    # keep it running
harness/dev-machine.sh /tmp/omp-dev-home 18999             # prints HOME=… and OMP=…
flutter run -d macos --dart-define=OMPANION_LOCAL_HOME=/tmp/omp-dev-home \
  --dart-define=OMPANION_DATA_DIR=/tmp/ompanion-data --dart-define=OMPANION_SECRET_PREFIX=dev
```

The app reads the three defines in `lib/app/dev_overrides.dart`: `OMPANION_LOCAL_HOME` is the `HOME` of
"this computer", `OMPANION_DATA_DIR` holds the app's database and files instead of the platform's
application support directory, and `OMPANION_SECRET_PREFIX` prefixes every keychain key. App instances
running at the same time each need their own server port, home, data directory and prefix; one demo
server shares its cycle among all its sessions.

`dev-machine.sh <home> <port>` runs `omp-home.sh <home> <port>`, adds `modelRoles.default: fake/fake-1`
so an omp started without `--model` uses the fake provider, links `<home>/.local/bin/omp` to
`.tools/omp/18.3.1/omp-<darwin-arm64|linux-arm64|linux-x64>` and creates `<home>/demo-project/README.md`
unless it exists. It prints `HOME=<home>` and `OMP=<home>/.local/bin/omp` as absolute paths and can run
again, e.g. after changing the port. Open sessions in `<home>/demo-project`: demo scenario 3 edits the
`README.md` of the session's directory.

omp also reads provider API keys from the environment it inherits. Start the app without them: with a
key set, picking a real model in the app makes a paid call.

With `--demo`, a request that finds no eligible queued turn is answered by the demo (`demo.ts`); queued
turns still come first. Each user prompt, steer or follow-up starts the next scenario of one cycle
shared by all sessions:

| # | Label | The model |
|---|---|---|
| 1 | `markdown` | streams headings, nested and numbered lists, a task list, a table, a ```` ```dart ```` and a `~~~sh` fence, inline code, a link, `$…$` and `$$…$$` math |
| 2 | `bash` | runs `ls -la`, then answers |
| 3 | `read` | reads `README.md`, then `edit`s its first non-empty line of at most 200 characters, adding or removing " (edited by the ompanion demo)", then answers |
| 4 | `todo` | creates three tasks in phase "Demo", then asks whether to start |
| 5 | `thinking` | streams three `reasoning_content` chunks, then the answer; on `fake/fake-think` omp shows a thinking block |
| 6 | `ask` | calls `ask` with one question and the options Option A and Option B, then repeats the answer |
| 7 | `slow` | streams 40 lines 500 ms apart (~20 s): time to pause, abort or steer |

- A tool result continues the scenario of the call it answers (labels `bash-answer`, `edit`,
  `edit-answer`, `todo-answer`, `todo-closed`, `ask-answer`).
- Requests without tools are side requests (compaction summaries and the like): they get `ok`
  (`served: "default"`) and do not advance the cycle.
- omp sends a todo reminder after the first answer that follows scenario 4 and does not end in a
  question (scenario 5's). The demo answers it by marking every task done (`todo-close`, then
  `todo-closed`), so the reminder comes once a cycle. Other injected messages get "Noted."
  (`continue`).
- `GET /control/requests` names the step behind every request: `served: "demo"`, `demo: "<label>"`.

## Recording fixtures

```sh
bun harness/record.ts <scenario|all> harness/fixtures
```

Needs `.tools/omp/18.3.1/omp-<platform>-<arch>` (`scripts/fetch_omp.sh`). Each scenario gets its own
fake provider, home and working directory in the system temp directory. The recorder fails, and keeps
that directory with `out.jsonl`, `in.jsonl` and `requests.json`, when a model request got the default
reply, a scripted turn went unused, a command failed, or omp exited non-zero. After writing it re-reads
the pair: every line decodes (protocol v2 chunks reassembled) and every command id has exactly one
`response`.

Every fixture starts at omp's `ready` line. The first line sent is
`{"id":"negotiate","type":"negotiate_protocol","protocolVersion":2}`, the last, after the session
settled, `{"id":"final-messages","type":"get_messages"}`: its response is omp's own transcript to
compare a replayed view against. Before the `negotiate` response omp emits
`extension_ui_request setWidget` (key `autoresearch`, from omp's bundled extension, repeated after
each run), `advisor_cost_changed` and `available_commands_update`. Timestamps, ids, temp paths,
ports, durations and `auto_retry_start.delayMs` change between recordings; the frame sequence does
not.

`companion-*` scenarios need the built companion (`cd companion && bun run build`). The recorder copies
`companion/dist/ompx.js` to `<home>/.ompanion/companion/18.3.1/ompx.js`, where the app uploads it on a
host, and starts omp with `-e` on that copy. `available_commands_update` then also lists `ompx`
(`source: "extension"`). Companion calls are prompts `/ompx {"callId":"recorder:<id>",…}` with RPC id
`<id>`; each gets its `response`, the `ompx` `reply` and a `prompt_result` with `agentInvoked: false`.
Frames are specified in `docs/contracts/ompx.md`.

| Fixture | Contents |
|---|---|
| `text-stream` | one prompt; a markdown answer sent in 5 chunks, which omp re-splits into 14 `text_delta` |
| `thinking` | `fake/fake-think`; `thinking_start`, 2 `thinking_delta`, `thinking_end`, then "The answer is **42**."; the message has a thinking block with `thinkingSignature: "reasoning_content"` |
| `tool-bash` | text plus a `bash` call `echo hi`; `tool_execution_start`, 2 `tool_execution_update`, `tool_execution_end` (`hi`); answer "The command printed \`hi\`." |
| `tool-read-edit` | `read notes.md` (tag `850C`), a hashline `edit` replacing line 4 (`beta` → `gamma`), answer; 3 assistant and 2 toolResult messages |
| `approval` | `tools.approvalMode: always-ask`; `bash echo approved` waits on `select` "Allow tool: bash…" [Approve, Deny] between `tool_execution_start` and its updates; answered Approve |
| `ask` | omp without the companion (with `-e companion/dist/ompx.js` the companion's `askDialog` sends an `ompx` `request` instead; see `docs/contracts/ompx.md`): `ask` with two questions: `select` [Red, Blue (Recommended), Other (type your own)] → Blue; `select` → Other; `editor` → "ompanion"; result `color: Blue`, `text: "ompanion"` |
| `todo` | `todo` init (one phase, two tasks) and two `done` calls over three tool turns; then `get_state` with `todoPhases` |
| `subagent` | subscription `events`; `task` starts background subagent `Echo`; parent `agent_end` `isTerminal: false` and `prompt_result` `sessionSettled: false`; `get_subagents` while Echo runs; `subagent_lifecycle`/`subagent_progress`/`subagent_event`; Echo calls `yield`; a second parent run on the `custom` async-result message; `session_settled`; `get_subagent_messages` |
| `abort` | the answer hangs after one delta; `abort`; assistant `stopReason: "aborted"`, `prompt_result` `status: "aborted"`; a second prompt completes |
| `steer-followup` | `steer` and `follow_up` sent while the first answer streams; one run with 3 turns and 3 user messages |
| `compaction` | two prompts, then `compact`; two scripted model calls write the summary and short summary; the transcript becomes `compactionSummary` plus the kept second turn |
| `compaction-prompt` | companion loaded; the `compaction` setup, then the prompt `/compact`: response `{agentInvoked: false}`, `ompx` `compaction.started`, `compaction.ended` with the committed `compaction` entry, then `command_output` "Compaction complete. Tokens: …"; no `auto_compaction_*` frame |
| `error-retry` | 12 HTTP 500 replies: an empty assistant message with `stopReason: "error"`, `auto_retry_start`, a second `agent_start` without an `agent_end` in between, the answer; `auto_retry_end` arrives after `session_settled` |
| `big-frame` | resumed session with three ~420 KB answers; the `get_messages` response (1,286,652 bytes) arrives as 5 `rpc_chunk` lines |
| `session-resume` | resumed two-prompt session: `get_state`, two `get_messages_page` (limit 2, then the cursor), `get_entries` (all, then `since`), `get_tree`, one new prompt |
| `companion-ask` | companion loaded; `ask` with two questions (a header, an option description and preview, one multi-select) arrives as `ompx` `request` `ask` after the tool call's `message_end`, before `tool_execution_start`; `state.snapshot` lists it under `requests`; the `extension_ui_response` answers Blue with a note plus Version and Commit; `request.settled`; `tool_execution_end` "User answers:\ncolor: Blue (note: Dark blue if possible)\nextras: [Version, Commit]"; the final answer |
| `companion-pause` | companion loaded; `pause.set true` after the first text delta (`pause.changed` precedes the reply); the stream still finishes with the `bash` call, which does not start; `get_state` (`isStreaming: true`) and `state.snapshot` (paused) while parked; `pause.set false`; `pause.changed`, then `tool_execution_start` and the rest of the run |
| `companion-queue` | companion loaded; `follow_up` during a 1 s pause in the answer; `queue.changed` `{followUp: ["Then summarize it."], count: 1}`; `queue.get`; after the first turn's `turn_end`, `queue.changed` empty and the follow-up turn |
| `companion-exec` | companion loaded; `exec.bash` `echo one; sleep 0.2; echo two; sleep 0.2; echo three`: three `exec.chunk` events with the call's `callId`, `message.appended` with the recorded `bashExecution` message (the same object `get_messages` returns), then the reply (`output: "one\ntwo\nthree\n"`, `exitCode: 0`); no model request |
| `companion-exec-streaming` | companion loaded; `exec.bash` `echo while-streaming` during a 0.8 s pause in the first answer: `exec.chunk` and the reply, but no `message.appended`; the run ends and settles; the next prompt's `response`, then `message.appended` with the held `bashExecution`, then its `agent_start`; the transcript is user, assistant, bashExecution, user, assistant |
