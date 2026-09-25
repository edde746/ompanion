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

## Frames (companion → app)

Every frame has `"type": "ompx"` and a `kind`.

| kind | Shape | Meaning |
|---|---|---|
| `reply` | `{type, kind, callId, ok: true, result}` | call succeeded |
| `reply` | `{type, kind, callId, ok: false, error: {code, message}}` | call failed |
| `event` | `{type, kind, event, data}` | pushed state change; every attached device sees it |
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

<!-- verb sections are appended by their implementers -->
