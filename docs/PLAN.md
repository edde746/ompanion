# omp-app — plan

Flutter client for [omp](https://github.com/can1357/oh-my-pi) with TUI parity, driving omp on many
machines without a host daemon. Reference product: [T3 Code](https://github.com/pingdotgg/t3code),
limited to omp.

Status: plan only, no code. Numbers were measured on this machine on 2026-09-25 (omp 18.3.0 installed,
source read at tags v18.3.0 and v18.3.1, Flutter 3.47.1, Dart 3.13.1) unless marked [INFERENCE].

| Doc | Contents |
|---|---|
| `parity.md` | the parity contract: every omp feature, its route, its surface, its milestone |
| `research/omp-surface.md` | RPC commands and frames, slash commands, CLI `--json`, approval frames, keybinding actions |
| `research/companion-reach.md` | what a companion extension can reach in 18.3.1, API paths, what stays unreachable |
| `research/integration-options.md` | RPC vs CLI vs files vs companion vs daemon, install paths |
| `research/remote-transport.md` | SSH, dartssh2, jump hosts, Tailscale, T3 Code's remote design, detached sessions |
| `research/windows-hosts.md` | Win32-OpenSSH behaviour, probes, install, attached and detached sessions |
| `research/voice.md` | omp voice and live mode, what a phone must do instead |

The research docs record every option considered, including rejected ones. This file records the
decisions.

## 1. Goal

- Every omp feature a TUI user can reach is reachable in the app, except the ones excluded in
  `parity.md` by decision.
- Machines: this computer (desktop), SSH, SSH through jump hosts, hosts behind NAT reached through a
  reverse tunnel, Tailscale.
- Client platforms: macOS, Linux, Windows, iOS/iPadOS, Android.
- Host platforms: macOS, Linux, Windows.
- Beyond omp: integrated terminal, file explorer and editor, port forwards.
- omp versions: 18.3.1 (the newest release today) and every later release as it ships. Nothing older.
- Out of scope: push notifications (later), T3-style git/PR panels, worktree-per-thread orchestration,
  live attach to running TUI sessions, omp's `/git` overlay, `omp commit`, collab, recording and
  streaming, Codex realtime voice (omp's `/live` model), plan mode and plan review, vibe mode.

## 2. Decisions

| # | Decision | Why / cost |
|---|---|---|
| D1 | No host daemon. The app drives stock omp: one `omp --mode rpc-ui` process per open session, `omp <cmd> --json` one-shots, SFTP, PTY. | User choice. Nothing to install beyond omp and one script. Cost: every gap in RPC goes through the companion (D3), and each open session is its own process with a cold start (1.7 s locally to `ready` plus four introspection commands). |
| D2 | `rpc-ui`, not `rpc`. | Only `rpc-ui` registers the `ask` tool and hands tools a UI context. It forces `PI_NO_PTY=1`, which is correct for a pipe. `--no-ui` would silence the companion and is not used. |
| D3 | RPC gaps are closed only by a companion extension: one script the app uploads and loads with `-e` into every rpc process. No upstream omp changes. | User choice. The companion reaches the live main session through `pi.pi.AgentRegistry.global().get(pi.pi.MAIN_AGENT_ID).session`, plus settings with their schema, auth storage, the model registry, session listing, tree navigation, labels, queues, subagent control, user bash and Python, `runEphemeralTurn`, themes (`research/companion-reach.md`). Cost: it depends on omp internals and must be built and tested per omp version. |
| D4 | Protocol v2 is mandatory. The Dart client negotiates v2 and reassembles `rpc_chunk` frames. | `get_available_models` fails on v1 with `RPC response exceeded the transport limit`; on v2 it is 8 chunks, 2,039,508 bytes, 1,039 models. Cached per machine and omp version. |
| D5 | Every session runs detached from the SSH channel: a per-session run directory, commands appended to `in.jsonl`, output appended to `out.jsonl`. POSIX hosts feed omp with `tail -f in.jsonl | omp`; Windows hosts start omp through WMI with job breakaway and a PowerShell byte pump (§5). | User choice. A dropped connection, a locked phone or a closed app no longer aborts the running turn. POSIX form verified on macOS; Windows form is an M0 spike. |
| D6 | Any device may send to a live session at any time. Appends are serialized by a short lock; every device also tails `in.jsonl` to see what the others sent. Dialogs are settled by the first answer. | User choice. omp ignores `extension_ui_response` frames with unknown ids, so a late second answer is harmless. |
| D7 | One SSH stack on every client platform: `dartssh2` 4.1.0 (MIT, 2026-09-04), pinned exactly. "This computer" on desktop uses `Process` with the same framing. | Only pure-Dart SSH works on iOS and Android. Covers exec, PTY, SFTP, `-L/-R/-D`, unix-socket forwards, jump-host chains, encrypted OpenSSH keys, keyboard-interactive, `none` auth. App-side work: known_hosts, an ssh-agent client, `~/.ssh/config`, ProxyCommand, dead-peer detection. Channel-stall fixes landed in 3.1.0 and 4.0.1, hence the exact pin. |
| D8 | Jump hosts are a connection property: an ordered chain, each hop with its own auth and host-key check. A host behind NAT with a reverse tunnel is a jump through the relay host to `localhost:<port>`. | `SSHClient(await jump.forwardLocal(target, 22))`, chainable. One code path for bastions and reverse tunnels. |
| D9 | Desktop reads `~/.ssh/config` through `ssh -G <alias>` and lists aliases from `Host` lines and `Include`. Phones: manual entry, pasted config, or import from a desktop. | No maintained Dart parser exists. `ssh -G` gives the effective config including `Match`. |
| D10 | Tailscale through the OS client; machines are dialed over SSH by MagicDNS name or 100.x address. Discovery: `tailscale status --json` on desktop, a Tailscale API token on any device, and machine import from a desktop (records only, never private keys). Tailscale SSH (`none` auth) works; desktop pre-trusts peers' `sshHostKeys`. | User choices (OS client; both discovery paths). Phones need the Tailscale app running. |
| D11 | Port forwards per machine: automatic `-L` for OAuth callback ports during `login`, user-defined `-L` for previews, `-R 9224` for the browser relay [INFERENCE: untested]. | RPC `login` redirects to the host's loopback (anthropic 54545, openai-codex 1455, …). Phones fall back to pasting the redirect URL. |
| D12 | Bootstrap: probe (POSIX `sh -l -s` script; Windows `powershell -EncodedCommand`), then install with the official installer pinned to a release and `--binary` (`-Binary` on Windows), or upload a release asset and check its SHA-256. Manual mode shows the commands. The absolute omp path is stored. | Auto and manual install were both requested. Without `--binary` the installer prefers `bun install -g`; on Windows `-Ref` alone means a source install. Non-login shells and fresh Windows sessions miss the install dir on PATH. |
| D13 | TUI sessions on the same machine are listed from disk and opened by resuming them in a new rpc process. | User choice. omp has no liveness marker for a TUI holding a session (`.lock.os` is a per-write gate), so the app warns when the file changed recently and offers fork instead (R6). |
| D14 | The app sends a slash command as prompt text only if the live `get_available_commands` list contains it. The companion registers the TUI-only names it implements (`/pause`, `/goal`, `/loop`, `/btw`, `/tree`, …), so typed commands keep working. | 40 TUI-only builtins are not handled in RPC; sent as text they reach the model as a paid turn (#13281). RPC does not reserve those names, so the companion may claim them. |
| D15 | License GPLv3. | User choice. Allows `xterm3` (AGPL-3.0-or-later, combinable under GPLv3 §13). |
| D16 | One codebase for every store. Features a store forbids are compiled out with `--dart-define` flags, or worked around. | User choice. Known cases: local omp and `~/.ssh` access inside the Mac App Store sandbox, host access from Flatpak, background execution on iOS, auto-update outside GitHub builds. |
| D17 | Flutter stack follows Plezy: `provider`, `drift`, `slang`, `window_manager`, `flutter_secure_storage`. Terminal `xterm3` 6.3.4. Code editor `re_editor` 0.10.0. Markdown renderer chosen in the M3 spike (`gpt_markdown` 1.3.0 vs a renderer over `markdown` 7.3.1). | Same conventions as the author's other Flutter app. `xterm` 4.0.0 has not shipped since 2024-02-27; `xterm3` is the most active fork. |
| D18 | Repository: Flutter app at the root, `companion/` (TypeScript, Bun) for the extension, `docs/`. | The app and the companion version together; the companion is built per supported omp version. |
| D19 | Material 3 look. omp theme palettes are not used for the app's own colours. | User choice. omp's `theme` settings stay editable as TUI settings. |

## 3. Architecture

```mermaid
flowchart LR
  subgraph App["Flutter app"]
    UI[Screens] --> SS[SessionStore per open session<br/>pure reducer]
    UI --> MS[MachineService per machine]
    SS --> RC[RpcClient<br/>JSONL, v2 chunks, ids]
    SS --> CC[CompanionClient<br/>ompx requests]
    CC --> RC
    RC --> SC[SessionChannel<br/>detached or attached]
    MS --> L[HostLink]
    SC --> L
  end
  L --> LP[LocalLink: Process + dart:io]
  L --> SL[SshLink: dartssh2 pool]
  SL -. jump chain .-> J[bastion / reverse-tunnel relay]
  subgraph Host["Machine"]
    R["omp --mode rpc-ui -e companion (one per open session)"]
    D[(run dir: in.jsonl, out.jsonl)]
    C["omp cmd --json"]
    P[PTY shell]
    F[(files, ~/.omp/agent)]
  end
  D --> R --> D
  LP --> D & C & P & F
  SL -->|exec tail / append| D
  SL -->|exec| C
  SL -->|pty| P
  SL -->|sftp| F
```

Layers, each owning one thing:

- `HostLink` — `exec(command, stdin)`, `pty(size)`, `sftp`, `forwardLocal/Remote`. Two implementations:
  `LocalLink`, `SshLink`. SSH connections are pooled per host, because sshd's `MaxSessions` default of
  10 counts exec, shell and sftp channels on one connection.
- `SessionChannel` — the byte stream to one omp process. `DetachedChannel` launches or finds the run
  directory, tails `out.jsonl` and `in.jsonl` from stored offsets, and appends commands.
  `AttachedChannel` owns the process's stdio directly.
- `RpcClient` — skips bytes before `ready` (shell noise), negotiates v2, validates and reassembles chunks
  (64 MiB cap), correlates responses by device-namespaced ids, exposes typed frames. Pure Dart, tested
  against recorded frames.
- `CompanionClient` — `ompx` requests and replies over the same channel (§6).
- `SessionStore` — `(view, frame) → view`. Rebuilt from `get_state`, `get_messages_page` and
  `get_entries(since)` on attach; events apply on top. Offset replay is an optimisation, never required
  for correctness. A run ends at `agent_end` only when `isTerminal !== false`, or at `session_settled`.
- `MachineService` — probe, install, companion upload, CLI one-shots with a cache, session index, file
  operations, forwards.

Machine records, host keys and settings live in drift; private keys and passwords in
`flutter_secure_storage`. Private keys never leave the device that created or imported them.

## 4. Machines

| Type | Reaches | Auth | Discovery |
|---|---|---|---|
| This computer (desktop) | `Process` | none | automatic |
| SSH | host:port | key (in-app, or ssh-agent on desktop), password, keyboard-interactive | desktop `~/.ssh/config`, manual, import |
| SSH through jump hosts | hop chain, then target | per hop | `ProxyJump` from `ssh -G`, manual |
| Reverse tunnel | relay host, then `localhost:<port>` | per hop | manual |
| Tailscale | MagicDNS name or 100.x over SSH | SSH key or Tailscale SSH `none` | `tailscale status --json` (desktop), Tailscale API token, import |

Per-host facts the app stores after the probe: OS, arch, libc, shell, home, agent dir, absolute omp path,
omp version, and for Windows the OpenSSH default shell and PowerShell version.

Liveness: dartssh2's keepalive never declares a peer dead, so the app pings with a timeout (3 × 15 s),
probes on app resume and network change, reconnects with jittered backoff, and stops on auth failure.

Session listing is one exec round trip on POSIX: a script prints `{path, size, mtime, header}` for every
`~/.omp/agent/sessions/*/*.jsonl`, reading only the fixed title slot and the header line. When the
session is open, the companion's `listAllSessions()` gives titles, message counts and status. Both honour
`--profile`, `PI_CODING_AGENT_DIR` and `--session-dir`.

## 5. Session processes

Closing an rpc process's stdin or stdout disposes the session, and dispose aborts the running turn
(`rpc-mode.ts` 837-840, `agent-session.ts` 4908). That is why sessions do not run on the SSH channel
itself.

### Detached (macOS and Linux hosts, and this computer on macOS/Linux)

Run directory `~/.omp-app/run/<runId>/`, mode 0700:

| File | Purpose |
|---|---|
| `in.jsonl` | every command from every device, one JSON line each |
| `out.jsonl` | omp's stdout, appended |
| `err.log` | omp's stderr |
| `meta.json` | session path, cwd, omp version, companion build, launch args, generation |
| `omp.pid`, `tail.pid`, `exit` | liveness and exit code |
| `overlay.yml` | per-launch `--config` overlay (below); its path is also the process marker |
| `in.lock/` | `mkdir` lock held for the duration of one append |

Launch (sent over stdin to `sh -s`; `$OMP` is the probed absolute path, `--session` is omp's alias of
`--resume`):

```sh
cd "$CWD" || exit 1
nohup sh -c 'tail -c +1 -f "$0/in.jsonl" & echo $! > "$0/tail.pid"; wait' "$D" 2>/dev/null </dev/null \
  | nohup sh -c '"$1" --mode rpc-ui --config "$0/overlay.yml" -e "$3" --session "$2"; echo $? > "$0/exit"' \
      "$D" "$OMP" "$SESSION" "$COMPANION" >> "$D/out.jsonl" 2>> "$D/err.log" &
```

- Attach: `tail -c +<offset+1> -F out.jsonl` and the same on `in.jsonl`. Devices keep their offsets.
- Send: take `in.lock`, append one line, release. Large payloads (images) are uploaded to a temp file
  first and appended with `cat` under the lock.
- Stop: kill the `tail`; omp drains and exits 0. Fallback SIGTERM (exit 143).
- Rotation: `out.jsonl` is truncated only while the session is settled; devices that missed the window
  resync from RPC state. A restarted omp gets a new run directory, never an old `in.jsonl`.
- Garbage collection: run directories whose omp pid is dead and whose session is closed are removed.
- Secrets never go through `in.jsonl`: API keys reach the companion as a 0600 file uploaded over SFTP and
  deleted after use.

Measured on macOS with omp 18.3.0: two independent appenders both got responses, and omp exited 0 two
seconds after its `tail` was killed. A FIFO instead of the inbox file does not work: omp never sees EOF on
a FIFO stdin on macOS. Not yet measured: survival after the launching SSH channel closes, Linux, BSD vs
GNU `tail` on truncation, log growth over a long session.

### Windows hosts (and this computer on Windows)

Same run directory layout under `%USERPROFILE%\.omp-app\run\<runId>\`. Differences, all from
`research/windows-hosts.md`:

- Launch: sshd puts the channel's first process in a job with `KILL_ON_JOB_CLOSE`, so children started
  with `Start-Process`, `start` or `&` die with the channel. omp is started through WMI
  `Win32_Process.Create` with `CREATE_BREAKAWAY_FROM_JOB` (0x01000000); WMI-created processes are
  outside that job. Command line: `cmd.exe /d /s /c "powershell -NoProfile -File feed.ps1 <run> |
  <omp.exe> --mode rpc-ui --config <run>\overlay.yml -e <companion> --session <path> >> <run>\out.jsonl
  2>> <run>\err.log"`. cmd redirection passes bytes through unchanged; PowerShell 5.1 redirection does
  not.
- Feed: `feed.ps1` is a byte pump from `in.jsonl` (opened with ReadWrite sharing) to stdout, polling
  every 50 ms, exiting when `in.jsonl.stop` appears. Its exit closes omp's stdin. Windows has no
  signals; closing stdin is omp's only graceful stop (`Stop-Process -Force` skips cleanup).
- Scripts run as `powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand
  <base64 UTF-16LE>`, which works under a cmd, PowerShell or bash default shell. cmd caps a line at
  8191 characters, so larger scripts are uploaded over SFTP and run with `-File`.
- Attach: SFTP stat and offset reads on `out.jsonl` and `in.jsonl`. Appends go over SFTP under an SFTP
  `mkdir` lock.
- Environment: a WMI child gets the provider's environment block, so `USERPROFILE`, `LOCALAPPDATA` and
  `PATH` are set explicitly [INFERENCE: M0 spike].
- Orphans: found by the overlay path in their command line through `Get-CimInstance Win32_Process`.
- If the M0 spike fails: attached `omp.exe` on a no-PTY exec channel, where the turn dies with the
  channel, until the detached form works.

### Per-launch config overlay

Every rpc process gets a `--config <run>/overlay.yml` the app writes. It forces
`speech.enabled: false` (otherwise the `ask` tool speaks on the host's speaker) and carries any
app-imposed session settings.

## 6. Companion extension

A TypeScript extension in `companion/`, uploaded to `~/.omp-app/companion/<omp-version>/` (outside omp's
auto-discovery roots, so the user's TUI never loads it) and passed with `-e`. It imports only exported
subpaths of `@oh-my-pi/pi-coding-agent`, which the compiled omp serves from its own bundle.

Wire:

- App → companion: RPC `prompt` with `/ompx <verb> <json>`. Extension commands run before the agent,
  even while streaming, and add nothing to the transcript. The request id rides in the JSON.
- Companion → app: `extension_ui_request` frames with `method: "ompx.<verb>"` written through
  `ctx.ui.output`, answered by `extension_ui_response` frames through `ctx.ui.pendingRequests`. Both are
  TypeScript-private fields; every use is feature-checked, with `setStatus` and `editor` frames as the
  fallback. Frames over 1 MiB are chunked by v2 up to 64 MiB.
- Push: the companion subscribes to `pi.on(...)` events, `AgentRegistry.onChange` and session events,
  and emits queue, roster, mode and settings snapshots.
- Detection: `ompx` appears in `get_available_commands` with `source: "extension"`; its first reply
  carries the companion build and `pi.pi.VERSION`.

What it implements, by class (details and API paths in `research/companion-reach.md`):

| Class | Items |
|---|---|
| Thin wrappers | settings with schema (type, enum, default, tab, group, scope provenance), model roles, session listing, fork, `/clear`, delete, queue list and dequeue, subagent steer/kill/revive, pause and resume, user bash with streaming and `excludeFromContext`, user Python, `/btw`, prompt history search, context breakdown, logout and account lists, account pin, full-fidelity `ask` via `ctx.ui.askDialog` |
| Rebuilt from session APIs | goal and guided goal (including continuation), loop (including `--while`/`--until` conditions and limits), `/omfg`, `/tan`, provider setup, agents dashboard, extensions control center, API-key login |
| App only, no companion | push-to-talk, reply TTS |
| Other routes | `/cleanse` (`omp cleanse` one-shot; `src/cleanse` is not exported), project-scope settings (edit `.omp/config.yml` over SFTP; rpc-ui watches it) |
| Unreachable | extension TUI components |

Anything that must keep working while no device is attached runs in the companion, not the app: goal
continuation, loop iterations, the pause gate. A detached session keeps going after the phone locks;
logic in the app would stop with it.

- Pause: `agentPauseGate` from `@oh-my-pi/pi-agent-core` (bundled root export, `agent/src/pause.ts`).
  `pause()` parks every agent loop in the process (main, subagents, advisor) at its next model call or
  tool start; nothing is aborted, queued messages stay queued, `abort` still unwinds a parked run.
  `resume()`, `paused`, `pausedAt` and `onChange` give the state the app shows. One rpc process holds
  one session, so pause is per session, the same scope as the TUI's `/pause`; the app adds "pause all
  sessions on this machine" by sending it to every live run. The gate stays engaged while no device is
  attached; any device can resume.
- Goal: `session.goalRuntime` (`createGoal`, `resumeGoal`, `pauseGoal`, `dropGoal`,
  `buildContinuationPrompt`), `getGoalModeState`/`setGoalModeState`, `sendGoalModeContext`. The TUI's
  continuation (`interactive-mode.ts` 2377-2418) sends `buildContinuationPrompt()` as a hidden
  `goal-continuation` message 800 ms after the agent settles, when the goal is active and nothing else
  is queued. The companion does the same on `agent_end`, gated by `goal.continuationModes` containing
  `interactive` (its default).
- Loop: `parseLoopArgs` and the limit runtime from `modes/loop-limit`, `evaluateLoopCondition` from
  `modes/loop-condition`, the `prompt`/`compact`/`reset` action from settings; each iteration waits
  until the session is not streaming, compacting or finishing post-prompt work (`interactive-mode.ts`
  2351-2515).

Version policy: `companion/` holds one build target per supported omp version, starting at 18.3.1. CI
runs the companion's tests against each supported version's published package. A host on an unknown
newer version gets the latest build with feature detection and a warning; a host older than 18.3.1 gets
an upgrade prompt.

## 7. Surfaces

Layout follows T3 Code. Desktop and tablet: a left sidebar of machines, projects and sessions with
running and waiting-for-input badges; transcript and composer in the center; a right dock with Agent
Hub, todos, session tree, files, terminal. Phone: the same screens, one at a time.

| Surface | Contents |
|---|---|
| Machines | add/edit, jump chain, keys, host-key trust, probe and install status, omp version, forwards, import/export |
| Session browser | all projects on a machine, search, pin, rename, delete, fork, recent-activity warning |
| Transcript | markdown, math, code, thinking, images, per-tool cards (bash, read, edit/write diff, eval, todo, task subagents, web, browser screenshots, tts), compaction dividers, virtualized |
| Composer | prompt, steer, follow-up, queue list with dequeue, attachments, `@` files, `/` palette from `get_available_commands`, model and thinking pickers, context and cost meter, push-to-talk |
| Dialogs | tool approval, `ask` (full fidelity), extension `select/confirm/input/editor`, login URL and code |
| Agent Hub | roster, progress, per-agent transcript, steer, kill, revive, usage |
| Session tree | branches, labels, branch from message, navigate with summary |
| Modes | goal (status, budget, pause/resume/drop), loop (prompt, limit, condition), pause/resume, fast, advisor, prewalk, with state in the composer bar; pause-all per machine in the sidebar |
| Config | settings, model roles, providers and accounts, MCP, plugins and marketplace, skills, memory, agents, advisor and WATCHDOG, extensions, the agent's own SSH hosts, omp's TUI theme |
| Usage and stats | `omp usage --json`, `omp stats --json` |
| Terminal | PTY on the machine, tabs |
| Files | tree, viewer, editor, diff against git |

## 8. Voice

omp's voice features run on the host's mic and speaker and are TUI-only (`research/voice.md`). The app
owns audio instead:

- Push-to-talk: on-device speech recognition, text into the composer, sent as `prompt`, `steer` or
  `follow_up`. Optional host engine: upload a 16 kHz WAV, the companion transcribes with
  `modelRoles.dictation`.
- Reply speech: on-device TTS driven by `message_update` deltas, following `speech.mode`
  (`assistant`, `all`, `yield`). Optional host voices through the companion's `tts` call and SFTP.
- Live conversation: on-device voice activity detection, recognition and TTS in a loop, with barge-in
  stopping speech and optionally sending `abort`. omp's own `/live` (Codex realtime over WebRTC) is
  excluded: private endpoint, Codex Desktop client headers.

## 9. Store builds

| Channel | Constraint | Handling |
|---|---|---|
| GitHub releases (desktop) | none | full feature set, auto-update |
| Mac App Store | sandbox: no child processes outside the container, no `~/.ssh` | flag off "this computer"; `~/.ssh` via a user-granted folder bookmark |
| iOS App Store | no background sockets | detached sessions make this safe; reconnect on resume |
| Google Play | foreground-service policy | no background service; reconnect on resume |
| Flathub | sandbox | "this computer" through `flatpak-spawn --host` with the permission, or flagged off |

## 10. Milestones

Each ends with a demo on real machines, not a green build.

| M | Deliverable | Gate |
|---|---|---|
| M0 | Spikes: dartssh2 on all five clients (key, agent, password, jump chain, Tailscale SSH); POSIX detached session survives SSH channel close on Linux and macOS; `in.jsonl`/`out.jsonl` truncation with BSD and GNU `tail`; Windows detached launch through WMI breakaway (survives channel close, environment and profile, file sharing between cmd `>>` and sftp-server, byte-exact output); Dart RpcClient with v2 against recorded frames; companion `ompx` round trip (settings read/write, session list, `askDialog`) on 18.3.1; companion pause while a tool runs and while streaming, then resume and abort-while-paused | each spike's result written to `docs/research/` |
| M1 | Machines: connection types, keys, known hosts, `ssh -G`, Tailscale discovery, import/export, probe, install, reconnect | add a machine through a jump host from a phone; install omp on a fresh Linux box and a fresh Windows box |
| M2 | Session runtime: open, new, resume, prompt, stream, abort, steer, follow-up, queue, approvals, `ask`, pause and resume, multi-device, reconnect and resync | lock the phone mid-turn, unlock: the turn finished and the transcript is complete; the desktop saw the same turn live; pause from the phone freezes the run on the desktop's view and resume continues it |
| M3 | Transcript: every renderer in §7, virtualization, large sessions; markdown renderer decided | open a session of hundreds of MB and scroll without dropped frames on a mid-range phone |
| M4 | Session management: browser, tree, labels, branch, fork, rename, delete, export, share, compaction, handoff, Agent Hub with control | — |
| M5 | Config parity: every config row of `parity.md` | — |
| M6 | Goal and guided goal with continuation, loop with limits and conditions, `/btw`, `/omfg`, `/tan` | a goal keeps continuing with every device disconnected; goal and loop runs match the TUI on the same prompt |
| M7 | Terminal, files, editor, user port forwards | — |
| M8 | Voice: push-to-talk, reply speech, live loop | — |
| M9 | Store builds per §9, signing, desktop auto-update | — |

## 11. Risks

| ID | Risk | Mitigation |
|---|---|---|
| R1 | The companion depends on omp internals, including TypeScript-private fields and rebuilt goal and loop logic; every omp release can break it, and goal and loop behaviour can drift from the TUI. | per-version builds and CI; feature checks with fallbacks; the rebuilds track `interactive-mode.ts` line by line per supported version |
| R2 | Detached sessions are shell plumbing; `tail` differences and log growth are unmeasured. | M0 spikes; rotation rules in §5 |
| R3 | The Windows detached form rests on WMI breakaway and a byte pump, neither tested yet. | M0 spike; attached fallback |
| R4 | `message_update` carries the whole accumulated message each time (O(n²) bytes per reply) and dartssh2 has no compression. | coalesce rendering; `set_event_filter` where it helps; truncate `out.jsonl` when settled |
| R5 | dartssh2 fixed channel-stall and flow-control bugs as late as 2026-09-03. | exact pin; transport soak test in M0 |
| R6 | Two writers on one session file: the app resumes a session a TUI still holds. omp only has per-write locks. | warn on recent mtime; offer fork |
| R7 | Concurrent devices race: two prompts land in either order; a dialog is answered twice. | ordered by `in.jsonl`; every device sees every command; unknown dialog ids are ignored by omp |
| R8 | A 2 MB model list and a cold start per session over slow links. | cache per machine and omp version |
| R9 | Private keys on phones. | secure storage; per-device keys installed through a one-time password login |
| R10 | Run-dir logs hold full transcripts on the host. | 0700 directory, same sensitivity as omp's own session files; secrets bypass them (§5) |

## 12. Open questions

All product decisions are answered: platforms, no daemon, install, tunneling, Tailscale, extra scope,
TUI sessions, notifications (later), session lifetime (detached everywhere), gap route (companion
only), omp versions (18.3.1 onward), host OSes, license (GPLv3), distribution (build flags), multi-device
(any device sends), phone discovery (import and Tailscale API), terminal-bound features (voice, on-device
loop), look (Material 3), modes (goal, loop and pause in; plan and vibe out).

Left to spikes, not to the user: markdown renderer (M3), every [INFERENCE] above. Working name:
omp-app.

## 13. Evidence

- omp source at tags v18.3.0 and v18.3.1, docs via `omp://`.
- Live RPC captures on 18.3.0: `get_available_commands` (57 commands: 41 builtin, 11 skill, 3 custom, 1 extension, 1 file), `get_state`, `get_login_providers`, `get_available_models` on v1 and v2.
- Detached-session probes on macOS: FIFO stdin (fails), inbox file plus `tail -f` pipe (works).
- pub.dev API, 2026-09-25: dartssh2 4.1.0, xterm 4.0.0 (2024-02-27), xterm2 5.2.0, xterm3 6.3.4, re_editor 0.10.0, gpt_markdown 1.3.0, flutter_markdown_plus 1.0.12, markdown 7.3.1, flutter_math_fork 0.7.4, super_sliver_list 0.4.1, drift 2.35.0, slang 4.19.2, provider 6.1.5+1, flutter_secure_storage 11.2.0, flutter_pty 0.4.2.
- T3 Code remote design: `docs/internals/remote.md`, `docs/user/remote-access.md`, `packages/ssh/src/*` in pingdotgg/t3code.
- Upstream threads: can1357/oh-my-pi#5742 (GUI request), #13281 (TUI-only commands over RPC).
