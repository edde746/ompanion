# ompx: app ↔ companion protocol

The companion is a TypeScript extension (`companion/`) loaded into every rpc process with
`omp --mode rpc-ui -e <companion.js>`. It registers the slash command `ompx`, which carries the calls below, and
`goal`, `guided-goal` and `loop` (see "Slash commands: goal, guided-goal, loop"). Everything below rides on the
ordinary omp RPC channel of that process (`docs/research/omp-surface.md`).

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

## Secret files

Calls travel through `in.jsonl` on the host, so a secret travels as a file: the app uploads it over SFTP as a
new file `<home>/.ompanion/tmp/OMPANION_<16 lowercase hex digits>.secret` with mode 0600 and names it in the call
(`settings.set` `valueFile`, `accounts.setKey` `keyFile`). The companion accepts only an absolute path of a
regular file, not a symbolic link, with that name, whose real path lies directly in the real path of
`<home>/.ompanion/tmp` (`<home>` is omp's home directory), and, except on Windows, whose mode is exactly 0600.
Anything else is `bad_request`, and that file is neither read nor deleted. A missing file is `not_found`. An
accepted file is deleted once read, also when the call then fails. The app deletes its upload after every call,
so a refused file does not stay behind.

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

`args: {}` → `result: {pause: Pause, queue: Queue, requests: {id: string, method: string, params: unknown}[],
goal: Goal | null, loop: LoopState | null}`

What a device needs on attach besides RPC `get_state`. `requests` are companion requests still open
(for example an `ask` dialog); each ends with `request.settled`. `goal` is the session's goal-mode goal (null when
there is none, after a drop and after the completion exit) and `loop` the loop state (see "Goal mode and loop mode:
common rules"); both override whatever a device carried over from before an attach or resync.

### pause.set

`args: {paused: boolean}` → `result: Pause`. Event `pause.changed` with `Pause` on every transition.

- Drives omp's process-wide `agentPauseGate`, the TUI's `/pause`: every agent loop of the process (main,
  subagents, advisor) parks before its next model call or tool start. A model stream already running
  and a tool already started finish first. A run started while paused waits before its first model
  call. Queued messages stay queued.
- RPC `abort` unwinds a parked run; the gate stays engaged until someone resumes.
- Setting the state the gate already has changes nothing and emits nothing.

### queue.get, queue.pop, queue.take, queue.clear

- `queue.get` `args: {}` → `result: Queue`.
- `queue.pop` `args: {}` → `result: Restored | null`: removes the last user-queued message, steering
  first, for restoring into the composer (the TUI's dequeue). `null` when there is none.
- `queue.take` `args: {mode: "steering" | "followUp", index: number}` → `result: Restored | null`: removes
  the message at `index` of `Queue.steering` or `Queue.followUp`, with the hidden notices queued right
  before it, as `queue.pop` does for the last one. `null` when `index` is past the end.
- `queue.clear` `args: {interrupt?: boolean}` → `result: {steering: Restored[], followUp: Restored[]}`:
  removes every user-queued message and returns them. Queued messages omp itself authored stay, unless
  `interrupt` is true: then only advisor cards stay, so the RPC `abort` that follows cannot deliver an
  internal steer and restart the run.

Stop, as the TUI's Esc does it: `queue.clear {interrupt: true}`, restore what it returns into the
composer, RPC `abort`, then `pause.set {paused: false}` when paused, because `abort` leaves the gate
engaged and the next run would park again.

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
- `valueFile` names a secret file (see "Secret files") holding the JSON value. Credentials (`isCredential`)
  must use it. A file without a JSON value is `bad_request`.
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

### run.idleExit

Event `{idleMs: number}`, no `callId`, sent once right before the companion ends the omp of a detached run that sat
idle for `idleMs`. Only a run's launch turns it on (`OMPANION_RUN` and `OMPANION_IDLE_EXIT_MS`, `host-launch.md`, "Idle
exit"); the control process never sends it. Code: `companion/src/idle.ts`.

- Idle means no session event, companion call or command, pause change or roster change for `idleMs`, and nothing an
  exit would cut short or lose: a turn, compaction, retry, handoff, user bash, post-prompt work, an admitted prompt or
  a session switch; queued steering or follow-up messages; background jobs or their undelivered results; the pause
  gate engaged; an open companion request; loop mode on, paused or not (it is not persisted); an `active` goal; a
  subagent `running`; a companion call or command in flight. Any of these starts the idle time again. A paused or
  budget-limited goal is restored from the session file, so it does not hold the run.
- After the event the companion closes omp's input the way the app's graceful stop does: on POSIX it kills the feeding
  `tail` in `tail.pid` (only while that pid's command line names the run's `in.jsonl`), on Windows it creates
  `in.jsonl.stop`. omp drains and exits 0, and `ompanion_exit` follows in `out.jsonl`.
- A prompt a device appends while omp stops is lost with the process.
- A failed stop is logged to omp's log and shown as an error notice, and tried again after another `idleMs`.

### notify.test

`args: {}` → `result: {}`. Sends a `test` push notification to the calling device, the `deviceId` prefix of the
`callId`, through the relay its registration file names; the control process answers it too. `not_found` when that
device has no valid registration (`<home>/.ompanion/push/<deviceId>.json`); `failed` with the relay's status and
error, or the network error, as the message. A `410` also deletes the registration unless the phone rewrote it
meanwhile. Code: `companion/src/notify.ts`.

The registration file, the payload and its encryption, the relay, and the `input`, `done` and `failed` notifications
a detached run sends by itself: `docs/contracts/push.md`. Those send no frame, except a `notify` warning, once per
process, for a registration file that is invalid and for a device the relay fails for (again after a later delivery
to it succeeded).

### Session verbs: common rules

Owner: CompanionSession (`companion/src/verbs/session.ts`, `companion/src/verbs/session/*.ts`).
`SessionState` is `{sessionId: string, sessionFile: string | null, leafId: string | null}`, read after the
verb ran. Times are epoch milliseconds.

Event `session.changed` `{reason: "fork" | "clear" | "delete" | "tree" | "label" | "new"} & SessionState`, no
`callId`: pushed after `session.fork`, `session.clear`, `session.delete` of the open session, `tree.navigate` and
`tree.label` succeed, and (`"new"`) after a `loop.mode: reset` loop started a new session, because omp sends no RPC
frame for them. Devices resync with `get_state`, `get_messages_page` and `get_entries`.

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
  its `.bak` copies. Only `<sessions root>/<project>/<file>.jsonl`, or a `.jsonl` file directly in the open
  session's directory, is accepted (`bad_request` otherwise); a missing file is `not_found`. A process whose
  session is not persisted (`--no-session`, such as the machine's control process) has no session directory:
  it accepts the sessions root only.
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

### session.localRoot

`args: {}` → `result: {path: string}`: the absolute, host-native directory `local://` resolves to for the open
session (omp's `resolveLocalRoot`): `<session file without .jsonl>/local`; on Windows, when that path reaches 180
characters, and for a process without a session file, `<temp dir>/omp-local/<session id>`. It may not exist yet.
The app writes composer attachments there over SFTP: uploaded files, which the prompt names as `@"<path>"` so omp
auto-reads them (omp refuses a prompt with an `@local://` mention), and pastes over 256 KB as `paste-<n>.md`, which
the prompt names as `local://paste-<n>.md`, as the TUI's "Attach as local file" does. Deleting the session
(`session.delete`) removes `<session file without .jsonl>/local` with the session's other artifacts; the temp-dir
form is left to the machine's temp cleanup, as omp leaves it.

### agents.list

`args: {}` → `result: {agents: AgentRow[]}`. `AgentRow` is omp's registry `AgentRef` without the live
session: `{id, displayName, kind: "main" | "sub" | "advisor", parentId?: string, status: "running" | "idle" |
"parked" | "aborted", sessionFile: string | null, createdAt: number, lastActivity: number, activity?: string,
history?: {agent?, modelRole?, resolvedModel?, resolvedModelIsFallback?, metrics?, readOnly?, outputPath?,
patchPath?, branchName?, nestedPatchPaths?}, lifecycle?: {responseAt?, acceptedAt?, terminalAt?}}`.
`createdAt` and `lastActivity` are epoch ms but not always whole: a parked subagent omp reads back from its
session file (on a task spawn, `agent://` or `history://` in a reopened session) takes `lastActivity` from the
file's `mtimeMs`, and `createdAt` from `birthtimeMs` when the transcript has no timestamp.

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
The run is recorded in the transcript as a `bashExecution` message, pushed as `message.appended`, and
`!command` goes into prompt history.

### exec.python

`args: {code: string, excludeFromContext?: boolean}`. The TUI's `$` / `$$` in the session's Python kernel.
Streams `exec.chunk {text}` like `exec.bash`, then `result: {output, exitCode: number | null, cancelled,
truncated, totalLines, totalBytes, outputLines, outputBytes, artifactId: string | null, displayOutputs:
({type: "json", data} | {type: "image", data, mimeType} | {type: "markdown"} | {type: "status", event})[],
stdinRequested: boolean}`. Recorded as a `pythonExecution` message, pushed as `message.appended`, and `$code`
goes into prompt history.

### exec.abort

`args: {}` → `result: {bash: boolean, python: boolean}` (what was running). Cancels user bash and user Python,
like Esc; aborting Python also stops the agent's own eval tool runs, as in the TUI. The cancelled call still
replies, with `cancelled: true`.

### message.appended

Event `{message: AgentMessage}`, no `callId` (every device applies it): the `bashExecution` or
`pythonExecution` message an `exec.bash` / `exec.python` call recorded, exactly as omp stores it and as
`get_messages` returns it. omp itself sends no frame for these messages. `excludeFromContext` runs are
recorded too, with `excludeFromContext: true`.
- Idle session: pushed right after omp appends the message, before the call's reply.
- Session streaming: omp holds the message until the next prompt starts and appends it right before that
  prompt's messages. The push comes then, before that run's `agent_start`; the call's reply came earlier.
- A session change before that prompt (new, switch, fork, branch, tree navigation) can put the message in
  another session or branch; then no push follows, and devices resync for the session change anyway.

Devices append it to the transcript, deduplicated by `role` + `timestamp`.

### compaction.started, compaction.ended

Events, no `callId`. omp sends no frame for a manual compaction (the `/compact` prompt, RPC `compact`) until it
ends: the prompt's response is `{agentInvoked: false}` at once and `command_output` "Compaction complete…" or
"Compaction failed: …" comes last; `auto_compaction_*` covers only automatic compactions.
- `compaction.started` `{}`: a compaction began making its summary (omp's `session.compacting` hook, which
  fires after omp's no-op checks, so "Nothing to compact" starts nothing). Background speculation is left out.
- `compaction.ended` `{entry: CompactionEntry | null}`: the committed `compaction` entry, as `get_entries`
  returns it without `details` and `preserveData`; or `null` when the compaction that started failed or was
  cancelled (seen within 250 ms). A committed compaction always ends with its entry, also an automatic one
  and one an extension supplied, with or without a start.

Devices show the run as compacting between the two and add the entry's divider, deduplicated like the
`compact` response's.

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
orgId, orgName, expires} | null}[]}[], logins: {provider: string, kind: "key" | "optional_key" | "flow"}[]}`.
`providers`: one row per provider with stored credentials, plus the current model's provider, plus every
provider omp does not define itself (added by models.yml or an extension), with or without auth. `active`: the
account this session uses (the TUI logout list's mark); `sticky`: the OAuth account pinned or affine to this
session (`/session pin`); `pinnable`: an OAuth account of the current model's provider. Tokens and keys are
never included. `logins`: one row per provider of omp's `/login` list. `key`: the login only asks for an API
key, which `accounts.setKey` stores the same way; `optional_key`: the key may be left empty (a local server);
`flow`: a browser, device-code or multi-prompt sign-in that only omp's `login` runs. omp gives extensions no
login kind at runtime, so the companion takes it from the auth policies of the omp release it is built
against; a provider added after that release is `flow`.

### accounts.logout

`args: {provider: string, credentialId: number}` → `result: {provider, credentialId, remainingSource: string |
null}`. Removes one stored credential and refreshes the provider's models; `remainingSource` names auth that
still applies (env, config). `not_found` when no such stored credential exists.

### accounts.pin

`args: {credentialId: number}` → `result: {provider, credentialId}`. Pins an OAuth account of the current
model's provider to this session. `busy` while streaming, `not_found` for an account of another provider or an
unknown id, `failed` without a model or when an `--api-key` / `models.yml` key overrides OAuth.

### accounts.setKey

`args: {provider: string, keyFile: string}` → `result: {provider, credentialId: number}`. `keyFile` names a
secret file (see "Secret files") holding the API key. The companion stores the trimmed key as omp's `/login`
stores a pasted key (`api_key`, `source: "login"`) and refreshes the provider's models; an empty key is
`bad_request`. The key never appears in a frame, an error or a log line. Provider-specific key validation that
some `/login` flows do is skipped.

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

### Goal mode and loop mode: common rules

Owner: CompanionGoalLoop (`companion/src/verbs/session/goal.ts`, `companion/src/verbs/session/loop.ts`). The
companion runs omp 18.3.1's TUI goal mode, guided goal and loop mode (`interactive-mode.ts`) inside the rpc process,
so a goal or a loop keeps going with no device attached: same grammar, state transitions, prompt texts, notice
texts, 800 ms delays and session-file entries. The differences are listed at the end of this section.

```ts
// omp's own goal, exactly as `goal_updated` carries it.
type Goal = {
  id: string; objective: string;
  status: "active" | "paused" | "budget-limited" | "complete" | "dropped";
  tokenBudget?: number; tokensUsed: number; timeUsedSeconds: number;
  createdAt: number; updatedAt: number; // epoch ms
};
type Limit = { kind: "iterations"; total: number } | { kind: "duration"; ms: number };
type Condition = { kind: "while" | "until"; command: string };
type LoopState = {
  paused: boolean;        // suspended (Esc, loop.suspend): the next idle user prompt resumes the loop
  prompt: string | null;  // repeated after every turn; null while waiting for the next prompt
  limit: null
    | { kind: "iterations"; total: number; remaining: number }
    | { kind: "duration"; ms: number; deadline: number }; // deadline: host epoch ms, set when the loop was enabled
  condition: Condition | null;
  iterations: number;     // automatic repetitions started so far
};
```

- Goal state reaches devices through omp's own `goal_updated` frame (`{type: "goal_updated", goal: Goal | null,
  state?: {enabled, mode: "active" | "exiting", reason?, goal}}`) and `state.snapshot`'s `goal`; the companion adds
  no goal event. Loop state has no omp frame: `loop.changed` and `state.snapshot`'s `loop`. Loop off is `null`.
- Refusals fail with the TUI's text: `unsupported` when `goal.enabled` is off ("Goal mode is disabled. Enable it in
  settings (goal.enabled)."); `failed` for plan or vibe mode ("Exit plan mode first.", "Exit vibe mode first.") and
  state conflicts; `bad_request` for malformed arguments. Verbs push no notices; the slash commands do.
- Goal verbs check plan mode, vibe mode and `goal.enabled` first, as every `/goal` does.

### goal.set

`args: {objective: string}` → `result: {goal: Goal}`. `/goal set <objective>`: starts a goal, or replaces a running
(active or budget-limited) one with a fresh id and zero usage. Turns the `goal` tool on, then submits the objective
as a visible user prompt: a turn of its own when idle, a steer while streaming. omp puts its hidden
`goal-mode-context` message in front of it. `failed` "Resume the current goal first, or drop it before setting a new
objective." for a paused goal; `bad_request` for a blank objective.

### goal.pause, goal.resume

`args: {}` → `result: {goal: Goal}`. `/goal pause` and `/goal resume`. Pausing stops continuations; `failed` "No
active goal to pause." without a running goal. Resuming reactivates a paused goal (also one over its budget) and
schedules a continuation 800 ms later; `failed` "No paused goal to resume.". RPC `abort` already pauses an active
goal inside omp.

### goal.drop

`args: {}` → `result: {goal: null}`. `/goal drop` after its confirmation (the verb does not ask; the app does).
omp emits `goal_updated` with status `dropped`, then clears the goal. Dropping a running goal restores the tools that
were on before goal mode; a goal dropped while paused leaves the `goal` tool on, as in the TUI. `failed` "No goal to
drop.".

### goal.budget

`args: {tokenBudget: number | null}` (an integer ≥ 1, or `null` for no budget) → `result: {goal: Goal}`. `/goal
budget N` / `off`. A budget at or below the usage makes an active goal `budget-limited`; a larger one (or none)
makes a budget-limited goal active again. Lifts the stall hold and schedules a continuation. `failed` "Resume the goal
before adjusting the budget." (paused), "No active goal.", "Goal is already complete.".

### goal.guided

`args: {initial: string | null}` → `result: null`. `/guided-goal [rough objective]`: turns the `goal` tool on and sends
omp's interview kickoff (`prompts/goals/guided-goal-interview.md` of omp 18.3.1, copied into the companion) as a
hidden synthetic developer prompt, queued as a follow-up while streaming. The model interviews the user in normal
turns and ends with `goal({op: "create"})`, which starts the goal and its continuations. `failed` "Goal mode is already
active. Use /goal to manage it, or /goal drop to start over." or the paused-goal text of `goal.set`.

### Goal continuation, completion and restore

- Continuation: 800 ms after each terminal `agent_end` (the turn settled) while loop mode is off (also when
  suspended), `goal.continuationModes` contains `interactive`, plan mode is off, the goal is enabled and `active`,
  and no stall hold applies. The text is omp's `goal-continuation.md`, built at that moment; it is sent as
  `promptCustomMessage({customType: "goal-continuation", display: false, attribution: "agent"}, {streamingBehavior:
  "followUp"})`, so omp prepends its `goal-mode-context`. When it is due, loop mode or plan mode turned on since
  cancels it; a streaming, compacting or post-prompt-busy session drops it (the next terminal `agent_end` schedules
  again); a prompt or companion call still being admitted, or a session switch, new session or branch still in
  progress, retries it 800 ms later. `agent_start` cancels a pending one.
- Failed submission: an objective or continuation that starts no turn (omp threw, shown as an error notice, or
  dropped it before the agent) schedules the next continuation 800 ms later; each further failure in a row doubles
  the wait, up to 60 s. A turn that starts resets it.
- Stall hold: after a continuation turn, its tool calls (name, arguments) and results (name, content, error) are
  hashed. None, or the same as the previous continuation's, holds further continuations until a non-synthetic user
  message, `goal.set`, `goal.budget` or a turn that was not a continuation.
- Completion: after the turn in which the model called `goal({op: "complete"})` ends, the companion writes
  `mode_change` `none` and a `custom` entry `goal-completed` `{objective, tokensUsed, tokenBudget, timeUsedSeconds}`
  and clears the goal (no `goal_updated` follows; `state.snapshot`'s `goal` is `null`). The tools stay as they are.
- Budget: omp marks the goal `budget-limited` and, when that happens at a tool result, steers the model once with a
  hidden `goal-budget-limit` message; no continuation follows.
- Restore: when the process starts, the last `mode_change` of the branch comes back: an active goal as `paused`
  (a `goal_paused` entry is written), a paused one as paused, each with the `goal` tool on. `switch_session` and
  `branch` (through omp's session-switch reconciler) keep a running goal running and clear the previous session's
  goal first, restoring its tools. `new_session` keeps the goal in memory, paused by omp's abort, as the TUI does.

### loop.enable

`args: {limit: Limit | null, condition: Condition | null, prompt: string | null}` (all three keys required) →
`result: {loop: LoopState}`. `/loop …` while loop mode is off. A duration's deadline starts now. A non-null `prompt`
is submitted at once like a typed prompt (steer behaviour) and becomes the loop prompt: at once when idle, once omp
accepted it while streaming. `failed` "Loop mode is already on."; `bad_request` for a malformed limit or condition.

### loop.suspend, loop.disable

- `loop.suspend` `args: {}` → `result: {loop: LoopState | null}`: the TUI's Esc on a loop. Drops the loop prompt,
  cancels a pending iteration and a running condition command; `paused: true`. The next idle user prompt resumes the
  loop with that prompt. No-op when off or already paused. It does not abort the running turn (RPC `abort` does).
- `loop.disable` `args: {}` → `result: {loop: null}`: `/loop` while on. No-op when off.

### Loop iterations

- Process-wide and not persisted: a loop survives new and switched sessions, not a restart.
- The loop prompt is the first user message of a run that started after a terminal `agent_end`, before any assistant
  message: a prompt a device sent while the session was idle. Steers and follow-ups never replace it, nor do prompts
  the companion submits itself (a goal's objective).
- 800 ms after each terminal `agent_end`, with a loop prompt: a busy session (streaming, compacting, post-prompt work,
  a prompt being admitted, a session switch, new session or branch in progress) retries 800 ms later. Then, in order:
  `loop.mode: reset` with vibe mode on disables ("Exit vibe mode before using reset loops. Loop mode disabled."); a
  spent limit disables ("Loop limit reached. Loop mode disabled."); the condition command runs (the session's cwd,
  `loop.conditionTimeoutMs`); one iteration is counted; `loop.mode: compact` compacts (warning "Nothing to compact (no
  messages yet)", errors "Compaction cancelled", "Compaction failed: …") and `reset` starts a new session and emits
  `session.changed {reason: "new"}`; a passed duration disables ("Loop time limit reached. Loop mode disabled."); the
  prompt is submitted with follow-up behaviour. A prompt that starts no turn, or fails (error notice), suspends the
  loop.
- `/loop N` runs the prompt N + 1 times: the typed first run counts no iteration.
- Condition verdicts, by exit status: `--while` continues on 0 and ends on 1 ("Loop condition `<cmd>` no longer holds.
  Loop mode disabled."); `--until` continues on 1 and ends on 0 ("Loop condition `<cmd>` is now satisfied. Loop mode
  disabled."). Any other status, a timeout or a spawn failure ends it too ("Loop condition `<cmd>` failed (exit N)[:
  <first output line>]. Loop mode disabled.", "… timed out after <timeout>. …", "… could not run: …"). `<cmd>` is
  cut to 60 columns. A loop the companion disables shows its message as an `info` notice.

### loop.changed

Event `{loop: LoopState | null}`, no `callId`: the whole state, pushed on every change (enable, prompt taken, iteration
counted, suspend, disable) and never for a state the devices already have.

### Slash commands: goal, guided-goal, loop

Extension commands with omp's descriptions. `get_available_commands` lists them with `source: "extension"` and omp's
fixed hint `"arguments"`; they run before the agent, also while it streams. Like the TUI's builtins they run outside
omp's prompt admission: the `prompt` is done (its `prompt_result` comes) at once, and a dialog they wait on holds
neither the goal continuation nor the loop. Dialogs are omp's own UI requests (`select`, `confirm`, `editor`);
notices are `notify` requests whose `notifyType` is `info` (the TUI's status line), `warning` or `error`. Every
`/goal` and `/guided-goal` first refuses plan mode, vibe mode and `goal.enabled` off (warnings, texts above).

| Input | State | Result |
|---|---|---|
| `/goal <objective>` | none | starts it (`goal.set`) |
| | running | info "Goal mode is already active. Use /goal to manage it, or /goal drop to start over." |
| | paused | warning "Resume the current goal first, or drop it before setting a new objective." |
| `/goal` | none | editor "Goal objective"; empty cancels |
| | running | select "Goal: `<summary>` (`<status>`)": Show details, Adjust budget…, Pause, Drop |
| | paused | select "Goal paused: `<summary>`": Resume, Show details, Adjust budget…, Drop |
| `/goal set [objective]` | any | `goal.set`; without an objective, the editor first |
| `/goal show` | any | info "No goal set.", or the lines `Objective: …`, `Status: <status>[ (paused)]`, `Tokens: <used> / <budget> (<left> left)` or `Tokens: <used> (no budget)`, `Time spent: <n>s|m|h|d` |
| `/goal pause`, `resume` | any | info "Goal mode paused." / "Goal mode resumed.", or the verbs' warnings |
| `/goal drop` | any | confirm "Drop goal?" / "This removes the goal record. Accumulated usage stays in the session log.", then info "Goal dropped."; warning "No goal to drop." |
| `/goal budget [N\|off]` | any | info "Goal budget set to N." / "Goal budget cleared."; error "Goal budget must be a positive integer or \`off\`." (N is read with `parseInt`: `12abc` is 12); the verb's warnings; without an argument, editor "Goal budget (number, \`off\`, or empty to cancel)" prefilled with the budget |
| `/guided-goal [idea]` | any | `goal.guided`; its refusals as notices |
| `/loop [count\|duration] [--while\|--until '<cmd>'] [prompt]` | off | enables; info "Loop mode enabled.[ Limited to `<limit>`.][ `<remaining>`.][ Continuing while\|until \`<cmd>\` succeeds.] Repeating it after each turn.\|Your next prompt will repeat after each turn. Esc suspends the ongoing loop; /loop again to disable."; parse errors are error notices with omp's `parseLoopArgs` texts |
| `/loop …` | on | disables, info "Loop mode disabled."; arguments are ignored |

`<summary>` is the objective, cut to 47 characters plus "…" when longer than 48. The paused menu's "Adjust budget…"
ends in "No active goal.", as in the TUI.

### Differences from the TUI

- The TUI holds a continuation or iteration while its editor has a draft; the machine cannot see a device's composer.
- A `/skill:` prompt does not become the loop prompt: rpc-ui runs skills outside the session's prompt path.
- The loop repeats the text omp sent the model (after prompt-template expansion); the TUI re-expands the typed text.
- A prompt that starts no turn leaves a waiting loop waiting; the TUI marks it paused.
- Images attached to `/goal <objective>` or `/guided-goal` are not forwarded: extension commands receive text only.
- A continuation due while a prompt or companion call is being admitted is retried 800 ms later instead of dropped.
- A continuation or iteration due while a session switch, new session or branch is in progress waits for it; the
  TUI's timers do not look, and would submit into the disconnected agent.
- A continuation after failed submissions backs off (doubling, up to 60 s); the TUI's main loop retries every 800 ms.
- A `reset` iteration shows no "New session started" line; devices resync and show the new session.
- The TUI-only paused plan mode ("Plan mode is paused — run /plan again to fully exit.") does not exist in rpc-ui.
- The app's budget field parses strictly: `12abc` is refused with the TUI's error text, where the TUI's `parseInt`
  takes 12. The typed `/goal budget 12abc` stays lenient.
- The app offers no budget field for a paused goal; the TUI's paused menu offers "Adjust budget…", which then fails
  with "No active goal.".
- A duration loop's time left is counted on the device's clock against the machine's `deadline`, so clock skew between
  the two shows in the label.
- The app's composer toolbar can show a goal and a loop at once; the TUI footer shows one mode segment (the goal wins).
- A synthetic developer message (the guided-goal kickoff, omp's continuation after a compaction) starts a new turn in
  the app's transcript, so the reply it prompts is not folded into the previous turn; like the TUI, the app shows no
  row for the message itself.

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
