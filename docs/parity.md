# Parity contract

Every user-facing omp feature (18.3.1) and how the app reaches it. A row is done when its surface works
against a real machine. Evidence: `research/omp-surface.md` (RPC, text builtins, CLI),
`research/companion-reach.md` (companion API paths), `research/voice.md`.

The tables are the target, not a status. What ships at 0.1 is the README's feature list. Rows without a surface of
their own:

- Not reachable: goal, guided goal and loop modes; `/btw`, `/fork` and `/clear` (TUI-only names the app does not
  send; their companion verbs exist, but the app does not call them); `/omfg`, `/tan` and `/cleanse`; the provider
  setup wizard; Claude Code and Codex import; prompt history search; `@` file completion in the composer; the
  sidebar's pause badge and pause-all per machine; magic keyword highlighting; user port forwards; voice; the
  agents dashboard; the extensions control center; editing `keybindings.yml`.
- Only by typing the command omp lists into the composer (sent as prompt text, its output shown in the chat):
  `/todo` edits, `/retry`, `/compact`, `/shake`, `/fresh`, `/handoff`, `/export` (the HTML stays on the machine),
  `/share`, `/move`, `/wt`, `/add-dir`, `/dirs`, `/fast`, `/extended-context`, `/skillful`, `/computer`, `/browser`,
  `/prewalk`, `/advisor`, `/rename`, `/pin`, `/session delete`, `/tools`, `/dump`, `/context`, `/jobs`, `/memory`,
  `/ssh`, `/security`, `/changelog`.
- Partly: the model catalog (no models page; the roles page refreshes the RPC model list), updating omp (the app
  installs 18.3.1 where omp is missing or older; it never runs `omp update`), and omp's TUI theme (generic rows on
  the settings page).

Route codes:

- `RPC` — typed RPC command, event or frame.
- `TXT` — builtin slash command sent as a prompt; ANSI output arrives as `command_output`.
- `CLI` — `omp <cmd> --json` over exec.
- `FS` — file access over SFTP or local IO.
- `CE` — companion extension, thin wrapper over a live object.
- `CE-R` — companion extension, TUI logic rebuilt from session APIs (high churn, R1).
- `APP` — implemented in the app alone.

Where both stock and companion routes exist, the stock route is used and the companion adds only
what stock lacks.

## Conversation

| Feature | TUI entry | Route | Surface | M |
|---|---|---|---|---|
| Prompt, stream, abort | Enter, Esc | RPC `prompt`, `abort`, events; abort first takes the queue back (companion `queue.clear` with `interrupt`) and releases a pause | composer, transcript | M2 |
| Waiting for a reply | — | RPC `prompt` acknowledgement, `agent_start`, `get_state.isStreaming`; APP marks the send | transcript row (elapsed seconds) | M2 |
| Steer, follow-up | Enter while streaming, Ctrl+Q | RPC `steer`, `follow_up` | composer | M2 |
| Queue after yield | `/queue` | RPC `follow_up` | composer | M2 |
| Queued message list, dequeue | Alt+Up | CE `getQueuedMessages`, `popLastQueuedMessage`, `clearQueue`; companion `queue.take` | queue rows in the composer (edit, remove) | M2 |
| Queue and interrupt modes | settings | RPC `set_steering_mode` etc.; persisted via CE settings | settings | M5 |
| Images | Ctrl+V, `@img` | RPC `images[]`; APP: a clipboard bitmap (`pasteboard`), an image file pasted, dropped or picked, an image an Android keyboard inserts | attachment chips | M2 |
| Paste and drop capture | bracketed paste (`[Paste #N]` over 10 lines or 1000 characters), Ctrl+V image, a path dragged into the terminal | APP: the field's paste (PasteTextIntent, context menu Paste) reads copied files, then a bitmap, then text; a paste over 10 lines or 1000 characters is a chip. Files and folders dropped on the chat pane (`desktop_drop`, macOS, Windows, Linux) | attachment chips; pasted-text preview with Paste inline | M2 |
| Large paste delivery | `[Paste #N]` chip expanded on submit; "Attach as local file" writes `local://paste-N.md` | APP: the paste's text goes into the message after the typed text; over 256 KB FS writes `paste-N.md` into CE `session.localRoot` and the message names `local://paste-N.md` | send | M2 |
| Attached files | `@path`, auto-read on submit (file-mentions.ts) | APP `@"<path>"` mention omp auto-reads: this computer's files where they are; other machines' via FS upload into CE `session.localRoot` (100 MB cap, progress) | send, file-mention rows | M2 |
| Read and reply images | image in the `read` result; terminal image protocols | `toolResult` image blocks (live and via `get_entries`); host image script (`fetchHostImage`, ffmpeg preview) over SSH | read card preview; markdown machine-path images with notices | M2 |
| `@` file mentions | `@` | FS file index | composer | M7 |
| Tool approvals | inline | RPC `extension_ui_request select` "Allow tool: …" Approve/Deny | inline request panel | M2 |
| `ask` tool | ask dialog | CE `ctx.ui.askDialog` (headers, previews, notes, multi-select); RPC select/editor fallback | inline question form | M2 |
| Extension dialogs | — | RPC `select/confirm/input/editor/cancel` | inline request panel | M2 |
| Extension status, widgets, notify | — | RPC `setStatus`, `setWidget` (`string[]`), `notify` | status bar, toasts | M2 |
| Todos | HUD, `/todo` | RPC `todoPhases`, `set_todos`; TXT `/todo …` | todo panel | M4 |
| Retry | F5, `/retry` | TXT `/retry`; RPC `set_auto_retry`, `abort_retry`, `auto_retry_*` | retry banner | M2 |
| Compaction | `/compact`, auto | RPC `compact`, `set_auto_compaction`; TXT modes | menu, divider | M4 |
| Shake, fresh | `/shake`, `/fresh` | TXT | menu | M4 |
| Handoff | `/handoff` | RPC `handoff` | menu | M4 |
| Force tool | `/force` | TXT | palette | M2 |
| Magic keywords | typed | passed through | composer highlight | M2 |
| User bash `!`, `!!` | `!` | CE `executeBash` (streamed, `excludeFromContext`), `abortBash` | composer | M2 |
| User Python `$`, `$$` | `$` | CE `executePython` | composer | M2 |
| Model mention `^` (tag a model for delegation) | `^` | RPC `prompt` carries `^provider/id`; omp expands it (pseudonym `m<N>`, `<model agent name/>` tag, `model_mention` entry, session agent for `task`). APP: the `^` list from `get_available_models`, filtered like the model picker; none in `!`/`$` drafts | composer chip, transcript and queue chips | M2 |
| Side question | `/btw` | CE `runEphemeralTurn` | side panel | M6 |
| `/omfg` | slash | CE-R (`runEphemeralTurn` + TTSR rule) | dialog | M6 |
| `/tan` | slash | CE-R | dialog | M6 |
| `/cleanse` | slash | CLI `omp cleanse` (not importable in compiled builds) | dialog | M6 |
| Context breakdown | `/context` | RPC `contextUsage`; CE breakdown | meter, panel | M2 |
| Tools list | `/tools` | RPC `dumpTools` | tools panel | M4 |
| System prompt, dump | `/dump` | RPC `systemPrompt`; TXT `/dump` | debug view | M4 |

## Modes

| Feature | TUI entry | Route | Surface | M |
|---|---|---|---|---|
| Pause and resume all agents of a session | `/pause` | CE `agentPauseGate` (`@oh-my-pi/pi-agent-core`): `pause`, `resume`, `paused`, `pausedAt`, `onChange` | toolbar, session badge, pause-all per machine | M2 |
| Goal mode (set, show, pause, resume, drop, budget) | `/goal` | CE-R (`goalRuntime`, `getGoalModeState`/`setGoalModeState`, `sendGoalModeContext`; continuation in the companion on `agent_end`) | goal panel, composer bar | M6 |
| Guided goal | `/guided-goal` | CE-R (interview prompt, then `createGoal`) | goal panel | M6 |
| Loop mode (prompt, limit, `--while`/`--until`) | `/loop` | CE-R (`modes/loop-limit`, `modes/loop-condition`; iterations in the companion) | loop control | M6 |
| Fast, extended context, skillful, computer, browser | slash | RPC `set_fast_mode`; TXT the rest | toggles | M2 |
| Prewalk | `/prewalk` | TXT; launch flags | toggle | M4 |
| Advisor | `/advisor` | TXT on/off/status/dump; CE settings for configure | advisor panel | M5 |

## Models and accounts

| Feature | TUI entry | Route | Surface | M |
|---|---|---|---|---|
| Model for this session | Alt+P, `/switch` | RPC `set_model`, `cycle_model`, `get_available_models` (v2) | model picker | M2 |
| Persistent model roles | Alt+M, `/model` | CE `setModelRole`, `setProjectModelRole`, provenance | roles page | M5 |
| Thinking level | Shift+Tab | RPC `set_thinking_level`, `get_available_thinking_levels` | picker | M2 |
| Model catalog, refresh | `omp models` | CLI `models --json` | models page | M5 |
| OAuth login | `/login` | RPC `login` → `open_url` + `input`; APP callback port forward | login dialog | M5 |
| API-key login | `/login` | CE-R (auth storage write; key delivered as a 0600 file) | providers page | M5 |
| Logout, account list | `/logout` | CE (credentials list/remove) | providers page | M5 |
| Account pin | `/session pin` | CE `pinCurrentProviderOAuthAccount` | providers page | M5 |
| Provider setup wizard | `/setup` | CE-R over `get_login_providers`, `login`, auth storage, settings | onboarding | M5 |
| Usage limits | `/usage`, `omp usage` | CLI `usage --json` per machine, `usage invalidate`; `config get auth.accountPolicies`, `retry.usageReservePct` for policy lines | usage pane (all machines, one entry per account) | M5 |
| Stats | `/stats`, `/trace` | CLI `stats --json` | stats page | M5 |

## Sessions

| Feature | TUI entry | Route | Surface | M |
|---|---|---|---|---|
| List sessions, all projects | `/resume` | FS listing script (CE `sessions.list` exists, unused) | session browser | M4 |
| Resume | `/resume` | launch `--session` | session browser | M2 |
| Read a session another omp process holds | — (another terminal, `omp -p`, another client) | FS listing script; host probe for write descriptors and omp's terminal breadcrumb (`contracts/session-writer.md`) | chat (read-only), sidebar badge | M4 |
| Take a held session over | — (after that omp exits) | re-probe, then launch `--session` | composer card, Take over | M4 |
| New | `/new` | launch without `--session` (a new run) | sidebar | M2 |
| Rename | `/rename` | RPC `set_session_name`; `session_info_update` | inline edit | M4 |
| Pin | `/pin` | TXT `/pin` | session browser | M4 |
| Delete | `/delete` | CE `deleteSessionWithArtifacts`; current session via `newSession({drop})` | session browser | M4 |
| Clear context in place | `/clear` | CE `resetSessionContext` | menu | M4 |
| Fork | `/fork` | CE `session.fork()` | menu | M4 |
| Branch from a message | `/branch`, double-Esc | RPC `get_branch_messages`, `branch` | message menu | M4 |
| Tree view | `/tree` | RPC `get_tree`, `get_entries` | tree panel | M4 |
| Reset to a message (same session file) | `/tree`, double-Esc | CE `navigateTree(id, {summarize})` (companion `tree.navigate`) | message menu, tree panel | M4 |
| Navigate tree with summary | `/tree` | CE `navigateTree(id, {summarize})` | tree panel | M4 |
| Labels | `/tree` | CE `sessionManager.appendLabelChange` | tree panel | M4 |
| Move, worktree, workspace dirs | `/move`, `/wt`, `/add-dir`, `/dirs` | TXT; CLI `worktree --json` | workspace menu | M4 |
| Import Claude Code / Codex session | `--from-claude`, `--from-codex` | launch flags | import dialog | M4 |
| Export HTML | `/export` | RPC `export_html`, then FS download | menu | M4 |
| Share | `/share` | TXT `/share` | menu | M4 |
| Prompt history search | Ctrl+R | CE `HistoryStorage.search` | composer | M5 |

## Agents

| Feature | TUI entry | Route | Surface | M |
|---|---|---|---|---|
| Subagent roster, progress | Alt+A, `/hub` | RPC `set_subagent_subscription`, `get_subagents`, `subagent_*` frames | Agent Hub | M4 |
| Subagent transcripts | Hub | RPC `get_subagent_messages` (`fromByte`) | Agent Hub | M4 |
| Steer, kill, revive subagent | Hub | CE `AgentLifecycleManager` (`ensureLive`, `release`) | Agent Hub | M4 |
| Agents dashboard | `/agents` | CE-R over settings, `discoverAgents`, advisor and prewalk calls; CLI `agents --json` | agents page | M5 |
| Background jobs | `/jobs` | TXT; CLI `ps --json` | jobs panel | M4 |
| IRC between agents | — | `irc_message` event | transcript | M4 |

## Extensibility and config

| Feature | TUI entry | Route | Surface | M |
|---|---|---|---|---|
| Settings (global) | `/settings` | CE registry with schema, `set`/`unset`, provenance | settings page | M5 |
| Settings (project scope) | `/settings` | FS edit `.omp/config.yml` (no companion writer; rpc-ui reloads it) | settings page | M5 |
| MCP servers | `/mcp …` | TXT add/remove/enable/disable/test/reload/resources/prompts/smithery-search; FS `mcp.json` | MCP page | M5 |
| MCP OAuth (reauth, unauth, reconnect, smithery login/logout) | `/mcp reauth` … | none: omp 18.3.1 answers these in RPC with "only available in the TUI client"; the app says so | MCP page | — |
| Plugins, marketplace | `/plugins`, `/marketplace` | CLI `plugin --json`, `plugin marketplace`, `plugin discover` (npm plugins need `bun` on the machine's PATH) | plugins page | M5 |
| Skills registry | `/skills` | CLI `skill search/info --json`; installed list from FS `skills.json` + `skills.lock.json` (no CLI lists them) | skills page | M5 |
| Invoke skill | `/skill:<name>` | RPC prompt | palette | M2 |
| Extensions control center | `/extensions` | CE-R (list loaded, persist disable, `reload`) | extensions page | M5 |
| Memory | `/memory …` | TXT; CE settings | memory page | M5 |
| Agent's own SSH hosts | `/ssh` | CLI `ssh --json`; TXT | hosts page | M5 |
| Security scans | `/security` | TXT | security page | M5 |
| omp TUI theme (`theme`, `theme.dark`, `theme.light`) | settings | CE settings; the app itself uses Material 3 (D19) | settings page | M5 |
| Keybindings | `keybindings.yml` | FS; APP shortcuts | shortcuts page | M5 |
| Changelog | `/changelog` | TXT | about | M5 |
| Update omp | `/update` | CLI `omp update`; installer | machine page | M1 |

## Voice

| Feature | TUI entry | Route | Surface | M |
|---|---|---|---|---|
| Push-to-talk dictation | hold Space | APP on-device recognition; optional CE host engine over SFTP WAV | composer | M8 |
| Reply speech | `speech.enabled` | APP on-device TTS from `message_update`; optional CE host voices | player bar | M8 |
| Live conversation | `/live`, Ctrl+L | APP on-device loop (VAD, recognition, TTS, barge-in) | live view | M8 |
| `tts` tool output | tool | RPC tool events, FS download | transcript | M8 |

## Outside omp

| Feature | Route | Surface | M |
|---|---|---|---|
| Machines, keys, known hosts, jump chains, import/export | APP | machines | M1 |
| SSH auth: key, password, keyboard-interactive, SSH config and agent, Tailscale SSH | APP (`ssh -G` for `IdentityAgent`, `IdentityFile`, `IdentitiesOnly`; server prompts after refused keys, like `ssh`) | machine editor, connect prompts | M1 |
| Install and upgrade omp | APP + installer | machines | M1 |
| Terminal | APP (PTY over SSH; local PTY on desktop) | terminal dock | M7 |
| File explorer, viewer, editor | APP (SFTP / local IO) | files dock | M7 |
| Port forwards | APP | machines | M7 |

## App-native equivalents

`/copy`, `/open`, `/hotkeys`, `/debug`, `/exit`, `/quit`, `/restart`: the app provides these itself.

## Excluded by decision

| Feature | TUI entry |
|---|---|
| Git overlay | `/git`, `omp git` |
| Commit message generation | `omp commit` |
| Collab host, join, leave | `/collab`, `/join`, `/leave` |
| Recording, clips, streaming | `/record`, `omp clip`, `omp play`, `omp stream` |
| Codex realtime voice (omp's `/live` transport) | `/live` |
| Plan mode, plan review | `/plan`, Alt+Shift+P, `/plan-review` |
| Vibe mode | `/vibe` |

Transcripts of TUI sessions that used an excluded feature still render its entries (mode changes,
plan files, live-delegation messages).

## Known gaps

| Feature | Reason |
|---|---|
| Extension TUI components, custom footers, headers, editors | RPC stubs `custom()`; `setWidget` carries `string[]` only |
