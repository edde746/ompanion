# ompx: app ↔ companion protocol

The companion is a TypeScript extension (`companion/`) loaded into every rpc process with
`omp --mode rpc-ui -e <companion.js>`. It registers one slash command, `ompx`. Everything below rides on
the ordinary omp RPC channel of that process (`docs/research/omp-surface.md`).

Verified on omp 18.3.1 (spike, 2026-09-25): `ctx.ui.output` is a function that writes any object as a
frame; `ctx.ui.pendingRequests` is a `Map`; a companion request answered with `extension_ui_response`
resolves with the whole response frame; the main session is
`pi.pi.AgentRegistry.global().get(pi.pi.MAIN_AGENT_ID).session`; `agentPauseGate` imports from
`@oh-my-pi/pi-agent-core`; `ompx` is listed by `get_available_commands` with `source: "extension"`.

## Calls (app → companion)

```json
{"id":"<rpcId>","type":"prompt","message":"/ompx {\"callId\":\"<callId>\",\"verb\":\"<verb>\",\"args\":{}}"}
```

- The argument is one line of JSON: `{callId, verb, args}`. `args` is always an object (`{}` when empty).
- `callId` is unique across devices: `<deviceId>:<counter>`.
- Extension commands run before the agent, even while it streams, and add nothing to the transcript.
- omp answers the `prompt` with a normal response and later `prompt_result{agentInvoked:false}`. The app
  ignores both except a failed response (`success:false`), which fails the call.
- A handler exception surfaces as omp's `extension_error` frame with `extensionPath: "command:ompx"`.
  The companion catches its own errors and answers with an error reply instead; `extension_error` means
  a companion bug.
- The reply is written before the handler returns, so it always precedes the call's `prompt_result`.
- A call whose argument is not `{callId, verb, args}` gets a `bad_request` reply; its `callId` is the
  argument's `callId` when that is a non-empty string, otherwise `null`. Unknown `args` keys are
  `bad_request` too.

## Frames (companion → app)

Every frame has `"type": "ompx"` and a `kind`.

| kind | Shape | Meaning |
|---|---|---|
| `reply` | `{type, kind, callId, ok: true, result}` | call succeeded |
| `reply` | `{type, kind, callId, ok: false, error: {code, message}}` | call failed |
| `event` | `{type, kind, event, data, callId?}` | pushed state change; every attached device sees it. `callId` only on events of a running streaming call |
| `request` | `{type, kind, id, method, params}` | companion asks the user something (for example `ask`) |

Error codes: `bad_request` (unknown verb, invalid args), `unsupported` (omp lacks the API the verb needs),
`busy` (session streaming or compacting where the verb needs idle), `not_found`, `failed` (anything else;
`message` carries the cause).

Answering a `request`:

```json
{"type":"extension_ui_response","id":"<id>","value":"<result as a JSON string>"}
{"type":"extension_ui_response","id":"<id>","cancelled":true}
```

The first answer wins. omp ignores responses with an unknown id, so a second device's late answer is
harmless. When a request settles the companion emits `request.settled {id}` so every device dismisses
its dialog.

Streaming verbs (for example `exec.bash`) emit `event` frames carrying their `callId` while running and
a `reply` at the end.

Frames above 1 MiB need protocol v2 (`rpc_chunk`); the app always negotiates v2.

## Fallback channel

If a future omp removes `ctx.ui.output`, the companion sends each frame as the text of
`ctx.ui.setStatus("ompx", <frame JSON>)`, which reaches the app as
`{"type":"extension_ui_request","method":"setStatus","statusKey":"ompx","statusText":"<frame JSON>"}`.
`hello` reports which channel is active; companion requests are unavailable on the fallback channel.

## Verbs

Each section below is owned by the agent that implements it and lists exact `args`, `result` and
events. Types use TypeScript notation.

### hello

`args: {}` → `result: {companion: {version: string}, omp: {version: string}, channel: "output" | "status", verbs: string[], events: string[]}`

`verbs` and `events` are sorted and cover every companion module.

### Core types

```ts
type Pause = { paused: boolean; pausedAt: number | null }; // host epoch ms the current pause began
type Queue = { steering: string[]; followUp: string[]; count: number };
type Restored = { text: string; images?: { type: "image"; data: string; mimeType: string }[] };
type Provenance = "env" | "runtime" | "overlay" | "project" | "global" | "default";
type SettingValue =
  | { path: string; value: unknown; provenance: Provenance }
  | { path: string; provenance: Provenance; redacted: true };
type Roles = {
  storage: "global" | "project";
  roles: {
    role: string; name: string; tag: string | null; section: "chat" | "kind";
    model: string | null; provenance: Provenance; global: string | null; project: string | null;
  }[];
};
```

### state.snapshot

`args: {}` → `result: {pause: Pause, queue: Queue, requests: {id: string, method: string, params: unknown}[]}`

What a device needs on attach besides RPC `get_state`. `requests` are companion requests still open
(for example an `ask` dialog); each ends with `request.settled`.

### pause.set

`args: {paused: boolean}` → `result: Pause`. Event `pause.changed` with `Pause` on every transition.

- Drives omp's process-wide `agentPauseGate`, the TUI's `/pause`: every agent loop of the process (main,
  subagents, advisor) parks before its next model call or tool start. A model stream already running
  and a tool already started finish first. A run started while paused waits before its first model
  call. Queued messages stay queued.
- RPC `abort` unwinds a parked run; the gate stays engaged until someone resumes.
- Setting the state the gate already has changes nothing and emits nothing.

### queue.get, queue.pop, queue.clear

- `queue.get` `args: {}` → `result: Queue`.
- `queue.pop` `args: {}` → `result: Restored | null`: removes the last user-queued message, steering
  first, for restoring into the composer (the TUI's dequeue). `null` when there is none.
- `queue.clear` `args: {}` → `result: {steering: Restored[], followUp: Restored[]}`: removes every
  user-queued message and returns them. Queued messages omp itself authored stay.

`Queue.steering` and `Queue.followUp` are the texts of user-queued messages (`"[Image]"` for an
image-only one). `count` is omp's `queuedMessageCount`, which also counts messages omp queued itself, so
it can exceed the two lists.

Event `queue.changed` with `Queue` whenever it differs from the last one pushed. omp emits nothing when a
message is queued, and nothing at all while a run is parked, so the companion checks on every session
event and every 250 ms while the session streams.

### settings.schema

`args: {}` → `result: {tabs: string[], settings: SettingSchema[], conditions: Record<string, boolean>}`

```ts
type SettingSchema = {
  path: string; // dotted id, as written in config.yml
  type: "boolean" | "string" | "number" | "enum" | "array" | "record";
  default: unknown; // null when omp has none
  isCredential: boolean;
  enumValues?: string[];
  items?: { values: string[]; label: string }; // closed vocabulary of an array
  pathScoped?: { valuesKey: string }; // entries may be {path(s)/pathPrefix(es), values | <valuesKey>} objects
  env?: { name: string; fallback: boolean | "blank" }; // false: the variable overrides every layer
  ui?: {
    // absent: config-file-only setting, no settings-panel row
    tab: string; group?: string; label: string; description: string; warning?: string;
    condition?: string; // row shown only while conditions[condition] is true
    options?: { value: string; label: string; description?: string }[] | "runtime";
    secret?: boolean; ordered?: boolean;
  };
};
```

- `tabs` and `settings` follow omp's settings panel order. omp orders a tab's groups by a table in
  `pi-tui` overlays, which the compiled omp does not export; groups keep their first-appearance order.
- `options: "runtime"` is filled in for `theme.dark` and `theme.light` (installed themes).
  `composer.shape` stays `"runtime"`: its registry lives in `pi-tui` overlays, so the app offers free
  text. Option values of number settings are strings, as omp declares them.
- `conditions` are omp's own settings-panel predicates, evaluated now.

### settings.get

`args: {paths?: string[]}` → `result: {settings: SettingValue[], conditions: Record<string, boolean>}`;
every setting, in schema order, when `paths` is absent. Unknown path: `not_found`.

- `value` is what the settings layers hold (runtime override, then `--config` overlay, project,
  global, default), ignoring the environment, like omp's settings panel; `null` when unset without a
  default. `provenance` names the layer that supplies the effective value; `"env"` means the variable in
  the schema's `env.name` overrides `value`.
- A configured credential is reported as `redacted: true` without `value`: replies are stored in the
  run directory's `out.jsonl`.

### settings.set

`args: {path: string, scope: "global" | "override", value?: unknown, valueFile?: string}` →
`result: SettingValue`. Exactly one of `value` and `valueFile`.

- `global` persists to the profile's `config.yml`, on disk before the reply. `override` holds for this
  omp process only (`provenance: "runtime"`).
- `valueFile` is an absolute host path of a file holding the JSON value; the companion reads and
  deletes it. Credentials (`isCredential`) must use it, because calls travel through `in.jsonl`.
- A value omp rejects (type, enum, validation) is `bad_request` with omp's message.
- omp has no writer for project settings: edit `<cwd>/.omp/config.yml` over SFTP; omp watches it and
  `settings.changed` follows.

### settings.unset

`args: {path: string, scope: "global" | "override"}` → `result: SettingValue`. `global` removes the key
from `config.yml` (on disk before the reply); `override` drops the runtime override.

Event `settings.changed` with `{settings: SettingValue[], conditions: Record<string, boolean>}`: the
settings whose effective value changed, from any source (these verbs, the config file watcher, other
extensions), batched per microtask.

### roles.get

`args: {}` → `result: Roles`

- `roles` are omp's known model roles: the built-ins it shows, then custom roles from cycle order,
  assignments and tags.
- `model` is the effective selector (`provider/id`, optionally `:thinking`); `null` means
  auto-selection. `global` and `project` are the values of those two layers.
- `storage` is the `modelRoleStorage` setting: where omp's model picker saves assignments.
- The `default` role pinned by omp's `--model` flag reports `provenance: "runtime"`.

### roles.set

`args: {role: string, model: string | null, scope: "global" | "project"}` → `result: Roles`

- `global` writes `modelRoles` in the profile's `config.yml`; `project` writes `<cwd>/.omp/config.yml`.
  `null` clears the role in that scope. On disk before the reply.
- It writes the assignment only; RPC `set_model` switches the live session's model.

Event `roles.changed` with `Roles` whenever the `modelRoles` setting changes.

### request.settled

Event `{id: string}`, once per companion request, when it is answered, cancelled, times out or is
aborted.

### Session verbs: common rules

Owner: CompanionSession (`companion/src/verbs/session.ts`, `companion/src/verbs/session/*.ts`).
`SessionState` is `{sessionId: string, sessionFile: string | null, leafId: string | null}`, read after the
verb ran. Times are epoch milliseconds.

Event `session.changed` `{reason: "fork" | "clear" | "delete" | "tree" | "label"} & SessionState`, no `callId`:
pushed after `session.fork`, `session.clear`, `session.delete` of the open session, `tree.navigate` and
`tree.label` succeed, because omp sends no RPC frame for them. Devices resync with `get_state`,
`get_messages_page` and `get_entries`.

### sessions.list

`args: {cwd?: string, all?: boolean, limit?: number (1-1000, default 100), offset?: number (default 0)}`;
`cwd` and `all` together are `bad_request`. Default: the open session's project (its `--session-dir` too).
`result: {total: number, offset: number, sessions: SessionRow[]}` where `SessionRow` is
`{path, id, cwd, title: string | null, firstMessage: string | null, created: number | null, modified: number,
messageCount: number, assistantTurns: number | null, size: number, status: "complete" | "interrupted" |
"aborted" | "error" | "pending" | "unknown", parent: string | null, pinned: boolean}`. Same list as the TUI
resume picker: pinned sessions first, then newest; untitled sessions without an answer are left out unless
pinned. `parent` is the header's `parentSession`: a session id for forks, a path for
`new_session {parentSession}`.

### session.fork

`args: {}` → `result: SessionState & {parentSessionFile: string | null}`. Copies the conversation into a new
file and continues there; the original file stays. `busy` while streaming; `failed` when the session is not
persisted (`--no-session`) or an extension cancelled it. Emits `session.changed {reason: "fork"}`.

### session.clear

`args: {}` → `result: SessionState & {droppedCount: number}`. The TUI's `/clear`: aborts compaction, then
drops the model context in place; the file and its transcript stay, `sessionId` rotates. `busy` while a turn,
user bash or user Python runs. Emits `session.changed {reason: "clear"}`.

### session.delete

`args: {path: string, dropCurrent?: boolean}`.
- Another session: `result: {deleted: string, current: false}`. Deletes the file, its artifact directory and
  its `.bak` copies. Only `<sessions root>/<project>/<file>.jsonl` or files in the open session's directory are
  accepted (`bad_request` otherwise); a missing file is `not_found`.
- The open session: needs `dropCurrent: true` (`bad_request` otherwise). The TUI's `/delete`: starts a new
  session and deletes the old file. `result: {deleted, current: true} & SessionState` (the new session).
  `busy` while streaming; `failed` when an extension cancelled the new session or the file survived. Emits
  `session.changed {reason: "delete"}`.

### tree.navigate

`args: {entryId: string, summarize?: boolean, customInstructions?: string}`; `customInstructions` needs
`summarize: true`. Moves the leaf inside the same file (`session.navigateTree`). A user message rewinds past
itself and returns its text for the composer; any other entry becomes the leaf. `summarize` makes a model
call and records a `branch_summary` entry for the abandoned branch at the target.
`result: {cancelled: true, aborted: boolean} | ({cancelled: false, aborted: false, editorText: string | null,
editorImages: ImageContent[], summaryEntryId: string | null} & SessionState)`. `aborted` means `tree.abort`
stopped the summary; nothing moved. `not_found` for an unknown entry, `busy` while streaming. Emits
`session.changed {reason: "tree"}` when it moved.

### tree.abort

`args: {}` → `result: {}`. Stops a running `tree.navigate` summary (Esc in the TUI).

### tree.label

`args: {entryId: string, label: string | null}`; `null` clears. `result: {entryId, label: string | null} &
SessionState`. `not_found` for an unknown entry. Emits `session.changed {reason: "label"}`.

### context.breakdown

`args: {}` → `result: {model: {provider, id, name} | null, contextWindow: number, usedTokens: number,
autoCompactBufferTokens: number, freeTokens: number, categories: {id: "systemPrompt" | "systemTools" |
"systemContext" | "skills" | "messages", label: string, tokens: number}[], snapcompact: object | null,
boundaries: {thresholdPercent: number, speculationPercent: number | null} | null}`. The TUI's `/context` as
data; `snapcompact` is omp's `ContextSavingsEstimate` when a snapcompact setting is on; `boundaries` are the
auto-compaction marks for a gauge (`null` when compaction is off).

### agents.list

`args: {}` → `result: {agents: AgentRow[]}`. `AgentRow` is omp's registry `AgentRef` without the live
session: `{id, displayName, kind: "main" | "sub" | "advisor", parentId?: string, status: "running" | "idle" |
"parked" | "aborted", sessionFile: string | null, createdAt: number, lastActivity: number, activity?: string,
history?: {agent?, modelRole?, resolvedModel?, resolvedModelIsFallback?, metrics?, readOnly?, outputPath?,
patchPath?, branchName?, nestedPatchPaths?}, lifecycle?: {responseAt?, acceptedAt?, terminalAt?}}`.

Event `agents.changed {agents: AgentRow[]}`, no `callId`: the whole roster, at most every 100 ms after
registry changes. Advisors are listed read-only, as in the TUI agent hub.

### subagent.steer

`args: {id: string, text: string}` → `result: {id, delivery: "steer" | "prompt"}`. Revives a parked agent,
then sends `text` with `streamingBehavior: "steer"`: `steer` when it joined a running turn, `prompt` when it
started a turn on an idle agent (the reply comes once that turn started). `not_found` for an unknown id,
`bad_request` for the main agent (use RPC `steer`) or an advisor, `failed` when the agent cannot be revived.

### subagent.kill

`args: {id: string}` → `result: {id, released: boolean, status: string | null}`. Aborts a running turn and
releases the agent with a tombstone, so it stays `aborted` and is never revived. Same id rules as
`subagent.steer`.

### subagent.revive

`args: {id: string}` → `result: {id, status: string | null}`. Brings a parked agent back to `idle`. `failed`
for an `aborted` agent. Same id rules as `subagent.steer`.

### exec.bash

`args: {command: string, excludeFromContext?: boolean}`. The TUI's `!` (`!!` with `excludeFromContext`) in
the user's shell, without a PTY. Output streams as events `exec.chunk {text: string}` carrying this call's
`callId` (omp throttles chunks to one per 50 ms), then the reply:
`result: {output, exitCode: number | null, cancelled, timedOut, truncated, totalLines, totalBytes,
outputLines, outputBytes, artifactId: string | null, workingDir: string | null, images: ImageContent[]}`.
The run is recorded in the transcript as a `bashExecution` message and `!command` in prompt history.

### exec.python

`args: {code: string, excludeFromContext?: boolean}`. The TUI's `$` / `$$` in the session's Python kernel.
Streams `exec.chunk {text}` like `exec.bash`, then `result: {output, exitCode: number | null, cancelled,
truncated, totalLines, totalBytes, outputLines, outputBytes, artifactId: string | null, displayOutputs:
({type: "json", data} | {type: "image", data, mimeType} | {type: "markdown"} | {type: "status", event})[],
stdinRequested: boolean}`. Recorded as a `pythonExecution` message and `$code` in prompt history.

### exec.abort

`args: {}` → `result: {bash: boolean, python: boolean}` (what was running). Cancels user bash and user Python,
like Esc; aborting Python also stops the agent's own eval tool runs, as in the TUI. The cancelled call still
replies, with `cancelled: true`.

### history.search

`args: {query?: string, limit?: number (1-1000, default 100)}` → `result: {entries: {prompt: string,
createdAt: number, cwd: string | null, sessionId: string | null, useCount: number}[]}`, newest first. Without
`query`: the most recent prompts. Reads omp's `history.db`, the store behind the TUI's Up arrow and Ctrl+R.
RPC prompts never reach it on their own (omp fires `input` only in the TUI), so the companion records every
user message the main session receives (prompts, steers, follow-ups, after template expansion) plus
`exec.bash` / `exec.python` lines; agent-injected messages are skipped.

### accounts.list

`args: {}` → `result: {sessionId, currentProvider: string | null, providers: {provider, name, source:
{kind: "runtime" | "config" | "oauth" | "api_key" | "env", envVar: string | null, concrete: boolean} | null,
sourceText: string | null, credentials: {credentialId: number, type: "oauth" | "api_key", label, detail,
active: boolean, sticky: boolean, pinnable: boolean, identity: {email, accountId, projectId, enterpriseUrl,
orgId, orgName, expires} | null}[]}[]}`. One row per provider with stored credentials, plus the current
model's provider. `active`: the account this session uses (the TUI logout list's mark); `sticky`: the OAuth
account pinned or affine to this session (`/session pin`); `pinnable`: an OAuth account of the current
model's provider. Tokens and keys are never included.

### accounts.logout

`args: {provider: string, credentialId: number}` → `result: {provider, credentialId, remainingSource: string |
null}`. Removes one stored credential and refreshes the provider's models; `remainingSource` names auth that
still applies (env, config). `not_found` when no such stored credential exists.

### accounts.pin

`args: {credentialId: number}` → `result: {provider, credentialId}`. Pins an OAuth account of the current
model's provider to this session. `busy` while streaming, `not_found` for an account of another provider or an
unknown id, `failed` without a model or when an `--api-key` / `models.yml` key overrides OAuth.

### accounts.setKey

`args: {provider: string, keyFile: string}` → `result: {provider, credentialId: number}`. The app uploads the
API key over SFTP as a mode 0600 file; the companion reads it, deletes it (always, also on failure), stores
the trimmed key as omp's `/login` stores a pasted key (`api_key`, `source: "login"`) and refreshes the
provider's models. `not_found` for a missing file, `bad_request` for an empty one. The key never appears in a
frame, an error or a log line. Provider-specific key validation that some `/login` flows do is skipped.

### btw

`args: {prompt: string, recordId?: string}`. The TUI's `/btw`: an ephemeral side turn over the current
context that adds nothing to the transcript, saved to the session's BTW history (the TUI's `/btw` history
shows it). `recordId` continues an earlier side conversation. Text streams as events `btw.delta {text}`
carrying this call's `callId`, then `result: {recordId: string, status: "complete" | "cancelled", answer:
string}`; the app shows `answer`, which can differ from the joined deltas (omp dedupes repeated replies).
One side question at a time: `busy` while another runs. `not_found` for an unknown `recordId`, `failed`
without a model or when the model call fails.

### btw.abort

`args: {}` → `result: {aborted: boolean}`. Cancels the running `btw`, which then replies with
`status: "cancelled"` and the text streamed so far.

<!-- verb sections are appended by their implementers -->

## Requests (companion → app)

### ask

Sent when omp's `ask` tool (or any extension) calls `ctx.ui.askDialog`, which the companion installs in
rpc-ui. Without it omp degrades `ask` to one `select`/`editor` dialog per question.

```ts
type AskParams = {
  questions: {
    id: string; question: string; header?: string;
    options: { label: string; description?: string; preview?: string }[];
    multi?: boolean; recommended?: number; // index into options
  }[];
  timeout?: number; // ms; from the `ask.timeout` setting, absent when 0 or in plan mode
  deadline?: number; // host epoch ms at which the timeout fires
};
type AskAnswer =
  | { kind: "submit"; results: { id: string; selectedOptions: string[]; customInput?: string; note?: string }[] }
  | { kind: "chat" };
```

- `results` has one entry per question, in order, with the same `id`. `selectedOptions` are option
  labels; at most one unless `multi`. `customInput` is the "Other" text.
- `chat`: the user wants to talk about it instead; the tool tells the model so.
- `cancelled: true` aborts the turn, like Esc in the TUI.
- The companion enforces the timeout itself, because no device may be attached: like the TUI dialog it
  answers every question with its recommended option (else the first), marked timed out.
- RPC `abort` while the question is open settles the request; later answers are ignored.
- An answer that does not fit the questions fails the tool call with an error the model sees.
