# omp 18.3.0 surface inventory

Sources: omp:// docs (the 18.3.0 installed-binary docs) and the source at `/tmp/oh-my-pi-18.3.0` (tag v18.3.0, same as the installed omp). Unverified claims are marked [INFERENCE].

Live capture on this machine (omp 18.3.0, `omp --mode rpc --no-session`, 2026-09-25):

- Cold start to `ready` plus four introspection commands: 1.7 s wall.
- `get_available_commands`: 57 commands — 41 `builtin`, 11 `skill`, 3 `custom` (`green`, `review`, `annotate`), 1 `extension` (`autoresearch`), 1 `file` (`init`). Non-builtin entries depend on the machine's skills, extensions and plugins.
- `get_state` keys: `autoCompactionEnabled contextUsage dumpTools fastModeActive fastModeEnabled followUpMode interruptMode isCompacting isStreaming messageCount model queuedMessageCount sessionId steeringMode systemPrompt thinkingLevel todoPhases tokensPerSecond`.
- `get_available_models` fails on protocol v1 with `RPC response exceeded the transport limit`. After `negotiate_protocol` v2 it arrives as 8 `rpc_chunk` frames, 2,039,508 bytes, 1,039 models. The client must implement v2 reassembly and cache the model list per machine.
- `get_login_providers` works; an extension emitted a `setWidget` `extension_ui_request` before the first response.

## 1. Feature table

Column meanings:
- **RPC** = reachable through `omp --mode rpc` / `rpc-ui` (exact command, event or frame). "text" means a builtin sent as `{"type":"prompt","message":"/cmd …"}`; its output comes back as `{"type":"command_output","text"}` and the reply carries `data.agentInvoked`.
- **No-daemon alternative** = a CLI `--json` subcommand, an SFTP file, or a companion extension ("CE") loaded into the rpc process.
- **GUI surface** = what the app needs to build.

| Feature | TUI entry | RPC | No-daemon alternative | GUI surface |
|---|---|---|---|---|
| Prompt and stream | Enter | `prompt`; events `agent_start/end`, `message_*`, `tool_execution_*`, `turn_*` | — | chat pane |
| Steer while streaming | Enter while streaming | `steer` or `prompt{streamingBehavior:"steer"}` | — | composer |
| Follow-up | Ctrl+Q / Ctrl+Enter | `follow_up` or `prompt{streamingBehavior:"followUp"}` | — | composer |
| Queue after yield | `/queue` | no (TUI-only) | emulate on the client | queue chip |
| Dequeue queued message | Alt+Up / Shift+Up | **no**; only `get_state.queuedMessageCount` | — | queue list (gap) |
| Queue modes | `/settings` | `set_steering_mode`, `set_follow_up_mode`, `set_interrupt_mode` (session-only, not persisted) | `omp config set steeringMode …` | settings |
| Abort | Esc | `abort`, `abort_and_prompt` | — | stop button |
| Images | Ctrl+V / `@img` | `images[]` on prompt/steer/follow_up | — | attachments |
| Model for this session | Alt+P, `/switch`, `/model <sel>` | `set_model` (not persisted), `cycle_model` (forward only), `get_available_models`; text `/switch <sel>` | `omp models --json [--kind]` | model picker |
| Persistent model roles | Alt+M, `/model` Roles view | **no** (`set_model` never persists a role) | `omp config set modelRoles '{…}'` (global); CE `settings.setModelRole` | roles page |
| Thinking level | Shift+Tab | `set_thinking_level`, `cycle_thinking_level`, `get_available_thinking_levels` (no auto/inherit) | config `defaultThinkingLevel` | picker |
| Fast / extended-context / skillful / computer / browser mode | slash commands | `set_fast_mode`; text `/fast`, `/extended-context`, `/skillful`, `/computer`, `/browser` | config keys | toggles |
| Plan mode, plan review, plan approval | `/plan`, Alt+Shift+P, `/plan-review` | **no** (ACP has it: session mode `plan` plus an Approve/Refine elicitation) | CE: none [INFERENCE: no AgentSession handle] | plan panel (gap) |
| Goal mode | `/goal`, `/guided-goal` | **no**; the `goal_updated` event is streamed | — | goal panel (gap) |
| Vibe mode | `/vibe` | **no** | — | worker panel (gap) |
| Loop mode | `/loop` | **no** | client re-submit, but no `--until/--while` gating | loop control |
| Prewalk | `/prewalk`, `--prewalk*` | text `/prewalk [restart]` | spawn flags | toggle |
| Advisor | `/advisor`, `/advisor configure` | text `/advisor on/off/status/dump`; `configure` replies "TUI-only" | SFTP `WATCHDOG.yml` / `.md`; config `advisor.*` | panel + WATCHDOG editor |
| Tool approvals | inline prompt | `extension_ui_request select` Approve/Deny (§4) | config `tools.approvalMode`, `tools.approval` | approval dialog |
| Ask tool | rich ask dialog | rpc-ui only, as select+editor fallback (§5) | — | question form |
| Todos | HUD, `/todo` | `get_state.todoPhases`, `set_todos`, text `/todo …`, todo tool results | SFTP export | todo panel |
| Compaction | `/compact [soft\|remote\|snapcompact] [focus]`, auto | `compact{customInstructions}`, `set_auto_compaction`, text `/compact …`; events `auto_compaction_*` | — | button + indicator |
| Shake / handoff / fresh | `/shake`, `/handoff`, `/fresh` | text `/shake`; `handoff`; text `/fresh` | — | menu |
| Retry | F5 / Alt+R, `/retry` | text `/retry` (agentInvoked true), `set_auto_retry`, `abort_retry`; events `auto_retry_*`, `retry_fallback_*` | — | retry banner |
| Clear context in place | `/clear` | **no** | — | gap |
| New session | `/new` | `new_session{parentSession?}` | — | button |
| Delete session | `/delete`, `/session delete` | text `/session delete` [INFERENCE: handled in text mode] | SFTP delete of JSONL + artifact dir | menu |
| Resume / switch session | `/resume`, `--resume` | `switch_session{sessionPath}` | SFTP list `~/.omp/agent/sessions/<enc-cwd>/*.jsonl` + `~/.omp/agent/session-pins.json`; text `/pin` | session browser |
| Import Claude/Codex session | `/resume @claude\|@codex`, `--from-claude/--from-codex` | **no** | spawn with the flag | import dialog |
| Fork whole session | `/fork`, `--fork` | **no** | spawn `omp --mode rpc --fork <id>` [INFERENCE] | menu |
| Branch from user message (new file) | `/branch` (`/rewind`), double-Esc | `get_branch_messages`, `branch{entryId}` | — | message menu |
| Tree navigation, labels, branch summaries | `/tree` | read-only `get_tree`, `get_entries{since}`; **no navigate** | CE `ctx.navigateTree(id,{summarize})`, `pi.setLabel` | tree panel |
| Rename | `/rename` | `set_session_name`; text `/rename` (no title = generate); `session_info_update` frame | — | inline edit |
| Move / worktree / workspace dirs | `/move`, `/wt`, `/add-dir`, `/remove-dir`, `/dirs` | text (all have handlers) | `omp worktree --json` | workspace menu |
| Export / dump / share | `/export`, `/dump`, `/share` | `export_html`; text `/dump`, `/share`; `get_state.systemPrompt` / `dumpTools` | `omp --export`, `omp share <id>` | menu |
| Trace / stats | `/trace`, `/stats` | text; starts a stats server inside the remote omp and the URL is that host's localhost | `omp stats --json` | stats page |
| Usage limits | `/usage` | text `/usage [show\|reset]` | `omp usage --json` | usage pane (all machines) |
| Context breakdown | `/context` | `get_state.contextUsage`, text `/context` | — | meter |
| Tools list | `/tools` | `get_state.dumpTools`, text `/tools` | — | tools panel |
| Background jobs | `/jobs` | text `/jobs` | `omp ps --json` | jobs panel |
| Agent Hub (subagents) | Alt+A, Ctrl+S, `/hub` | `set_subagent_subscription`, `get_subagents`, `get_subagent_messages`; frames `subagent_lifecycle/progress/event`; **no steer/kill/revive** | SFTP `<session>/<AgentId>.jsonl`, `__advisor*.jsonl` | hub panel |
| Agents dashboard (per-agent model/prewalk/advisor) | `/agents` | **no** | config `task.agentModelOverrides`, `task.agentAdvisor`, `task.agentPrewalk`; `omp agents unpack --json` | agents page |
| Settings | `/settings` | **no** | `omp config list/get/set/reset --json` (JSON lacks tab/group/label/enums/default; human `list` output has tabs and `(a\|b)` enums); CE live `settings` | settings page |
| Provider setup (sign-in + web search) | `/setup` (`/providers`) | **no** | config + login | onboarding wizard |
| OAuth login | `/login` | `get_login_providers`, `login` → `open_url` + `input`; prompts marked secret fail | `omp login [p]` over an SSH PTY; CE `ctx.modelRegistry.authStorage` | login dialog |
| Logout / account pin | `/logout`, `/session pin` | **no** logout; text `/session pin [account]` | `omp auth-broker logout` (broker mode only) | accounts page |
| MCP servers | `/mcp …` | text (add/list/remove/test/reauth/unauth/enable/disable/smithery-*/reconnect/reload/resources/prompts/notifications) | SFTP `.omp/mcp.json`, `~/.omp/agent/mcp.json` | MCP page |
| Marketplace / plugins | `/marketplace`, `/plugins`, `/reload-plugins` | text (RPC reloads skills and commands automatically) | `omp plugin … --json`, `omp install --json` | plugins page |
| Skills registry | `/skills` | **no** (TUI-only) | `omp skill search/info --json`, install/update/uninstall | skills page |
| Invoke a skill | `/skill:<name>` | via prompt (`dispatchRpcSkillPrompt`), when `skills.enableSkillCommands` is on | — | palette |
| Memory | `/memory …` | text | config `memory.*` | memory page |
| SSH hosts (the agent's ssh tool) | `/ssh …` | text | `omp ssh … --json` | hosts page |
| Security scans | `/security …` | text | — | security page |
| Collab host / join / leave | `/collab`, `/join`, `/leave` | **no** | `omp collab list --json`, `omp collab link <id> [--view] --json`; the GUI could speak the collab-web guest protocol | collab panel |
| Side questions | `/btw` | **no** | CE `ctx.runEphemeralTurn` [INFERENCE]; SFTP `<artifacts>/btw-history/` | side panel |
| `/tan`, `/omfg`, `/cleanse` | slash | **no** | `omp cleanse`, `omp ttsr --json` | gap |
| Git UI | `/git` | **no** | GUI-native git over SSH exec | git panel |
| Copy / open link, hotkeys, changelog, debug | `/copy`, `/open`, `/hotkeys`, `/changelog`, `/debug` | text `/changelog` only | — | GUI-local |
| Pause all agents | `/pause` | **no** | — | gap |
| Voice / record / stream | `/live`, Ctrl+L, hold Space, `/record` | **no** | `omp say`, `omp play`, `omp clip`, `omp stream` | native |
| User shell | `!cmd` / `!!cmd` | `bash{command}` (no chunk streaming, no excludeFromContext), `abort_bash` | — | shell input |
| User Python | `$` / `$$` | **no** | — | gap |
| Force tool | `/force <tool> [prompt]` | text | — | menu |
| Magic keywords | typed words | passed through in the prompt | config `magicKeywords.*` | editor highlighting |
| Theme, keybindings | `/settings` Appearance, `keybindings.yml` | extension `setTheme` unsupported | SFTP `~/.omp/agent/themes/*.json`, `keybindings.yml` | GUI theme and shortcuts |
| Prompt history search | Ctrl+R | **no** | SQLite history (history-storage.ts; path not verified) | history search |
| Extension UI | — | `extension_ui_request` select/confirm/input/editor/cancel/notify/setStatus/setWidget (string[] only)/setTitle (needs `PI_RPC_EMIT_TITLE=1`)/set_editor_text/open_url | — | dialogs, toasts, status bar |
| Extension custom components / footer / header / editor | — | not supported (`custom()` returns undefined) | — | none |
| Host tools / URI schemes | — | `set_host_tools`, `set_host_uri_schemes`, `host_tool_*`, `host_uri_*` | — | GUI-provided tools |
| Notices / errors / commands | — | `notice`, `extension_error`, `available_commands_update`, `prompt_result`, `config_update` | — | toasts, palette |

## 2. Slash commands (v18.3.0 source, confirmed by the live capture)

`get_available_commands` returns entries in this order: builtins with `handle`, then skills, extensions, custom / mcp_prompt, and file commands (`available-commands.ts`). The description shown is `acpDescription` when set, otherwise `description`.

### 2a. The 41 builtins RPC lists and handles (source `builtin`)

| Name (aliases) | RPC description | Hint |
|---|---|---|
| security | Plan, run, inspect, import, and compare OMP-native security scans | `<plan\|scan\|status\|cancel\|scans\|show\|import\|export\|validate\|compare\|disposition>` |
| model (models) | Show current model selection | — |
| switch | Switch model for this session only | [model] |
| fast | Toggle fast mode | [on\|off\|status] |
| skillful | Toggle skill listing | [on\|off\|status] |
| extended-context | Toggle extended context | [on\|off\|status] |
| computer | Toggle computer use | [on\|off\|status] |
| prewalk | Arm or restart prewalk | [restart] |
| advisor | Toggle advisor | [on\|off\|status\|dump [raw]\|configure] |
| export | Export session to HTML file | [--themes] [path] |
| trace | Open this session's trace in the stats dashboard | — |
| dump | Return full transcript as plain text, with LLM request JSON path | — |
| share | Share session via an encrypted link (share server or secret gist) | — |
| browser | Toggle browser eval-prelude headless vs visible mode | [headless\|visible] |
| todo | Manage todos | `<subcommand>` (edit, copy, expand, collapse, export, import, append, start, done, drop, rm) |
| session | Show or configure the current session | [info\|delete\|pin [account]] |
| jobs | Show background jobs | — |
| usage | Show token usage | [show\|reset [provider/credential-id\|provider/active]] |
| stats | Launch the local stats dashboard | [--port] [--host] |
| changelog | Show changelog | [full\|last [N]] |
| tools | Show available tools | — |
| context | Show context usage | — |
| mcp | Manage MCP servers | `<subcommand>` |
| ssh | Manage SSH connections | `<subcommand>` (add, list, remove, help) |
| fresh | Reset provider stream state without changing the local transcript | — |
| compact | Compact the conversation | [soft\|remote\|snapcompact] [focus] |
| shake | Shake heavy content out of the conversation context | [elide\|images\|thinking] |
| handoff | Summarize the session into a handoff document and compact in place | [focus instructions] |
| pin | Pin or unpin a session at the top of the resume list | [session id] |
| retry | Retry the last failed agent turn | — |
| memory | Manage memory | `<subcommand>` (view, stats, diagnose, queue, sync, clear/reset, enqueue/rebuild, mm list/show/refresh/history/seed/delete/reload) |
| rename | Rename the current session (omit title to generate) | [title] |
| move | Move the current session to a different directory | [<path>] |
| wt (worktree) | Move this session into a new worktree, changes included | [<branch>] |
| add-dir | Add a workspace directory to this session | <path> |
| remove-dir | Remove a workspace directory from this session | <path> |
| dirs | List this session's workspace directories | — |
| marketplace | Manage plugins from marketplaces | `<subcommand>` (add, remove, update, list, discover, install, uninstall, installed, upgrade, help) |
| plugins (plugin) | Manage plugins | [list\|enable\|disable] |
| reload-plugins | Reload all plugins | — |
| force (force:) | Force next turn to use a specific tool | <tool-name> [prompt] |

### 2b. The 40 TUI-only builtins

RPC does not list these. Sent over RPC they become **prompt text for the model**.

| Command | Description (TUI) | TUI implementation |
|---|---|---|
| settings | Open settings menu | `SettingsSelectorComponent` (full screen) |
| setup (providers) | Open provider setup | `showProviderSetup` wizard |
| plan | Toggle plan mode | `handlePlanModeCommand` + plan-proposal handler |
| plan-review | Re-open the plan review | Plan Review overlay |
| vibe | Toggle vibe mode | `handleVibeModeCommand` |
| goal | Toggle goal mode (set/show/pause/resume/drop/budget) | `handleGoalModeCommand` |
| guided-goal | Agent interviews you, then sets goal | controller |
| loop | Toggle loop mode | `handleLoopCommand` |
| queue | Queue a message for after yield | controller |
| collab / join / leave | Live sharing | CollabController + QR component |
| copy / open | Copy or open conversation content | `CopySelectorComponent` |
| hotkeys | Keyboard shortcuts | markdown panel |
| extensions (status) | Extension Control Center | `ExtensionDashboard` |
| agents | Agents hub | agents dashboard |
| git | Git UI | `showGitOverlay` |
| hub | Agent Hub | `AgentHubOverlayComponent` |
| branch (rewind) | Rewind to a message | `RewindSelectorComponent` |
| fork | Fork | `handleForkCommand` |
| tree | Session tree | `TreeSelectorComponent` |
| login / logout | OAuth | `OAuthSelectorComponent`, `LoginDialogComponent`, `LogoutAccountSelectorComponent` |
| new / clear / delete / resume | Session lifecycle | controllers, `SessionSelectorComponent` |
| btw / tan / omfg / cleanse | Side work | controllers |
| debug | Debug selector | `DebugSelectorComponent` |
| exit / restart / quit (q) | Process | — |
| skills | Registry | TUI handler |
| live / record / pause | Voice, recording, freeze all agents | controllers |

### 2c. Non-builtin sources (machine-dependent)

Live capture on this machine: 11 `skill:<name>` entries (only when `skills.enableSkillCommands` is on), extension `autoresearch`, custom `green` / `review` / `annotate`, file `init`. Other sources: `mcp_prompt` from MCP servers; file commands from `.omp/commands`, `~/.omp/agent/commands`, and claude / codex / opencode / agents / plugin command directories. `annotate` errors on its text-annotation path without a UI; `review` builds a headless prompt when there is no UI.

## 3. Interactive flows with no RPC equivalent

These are the TUI-only rows above.

The TUI implements almost all of them as custom TUI components mounted by `selector-controller.ts` / `command-controller.ts`. They are not extension UI, so no frames exist for them.

Only two TUI flows use extension-UI primitives that do reach RPC:
- approvals, through `select`
- the ask fallback, through `select` + `editor`

The TUI `select` is collab-aware (`showCollabAwareSelector`).

Login over RPC is partial:
- `open_url` + `input` frames are emitted only after the provider produces an auth URL.
- A prompt marked `secret` fails with "requires secret input, which is not supported in RPC mode".
- A prompt before the URL fails too.

In ACP, plan mode is a session mode (`default` / `plan`), and approval is an elicitation with "Approve and execute" / "Refine plan".

## 4. Tool approval frames

Policy: `tools.approvalMode` defaults to `yolo`, so nothing prompts unless the mode is `always-ask` or `write`, `tools.approval.<tool>` is `prompt`, a bash safety override fires, or provider safety checks apply.

**RPC, both `rpc` and `rpc-ui`.** The extension runner is always created and every tool is wrapped (sdk.ts ~2916/3036). The runner's UI context becomes the RPC one, so `hasUI()` is true.

The server emits:
```json
{"type":"extension_ui_request","id":"<snowflake>","method":"select","title":"Allow tool: bash\n[Origin: MCP server tool]\n[Reason: …]\n<formatApprovalDetails lines>[\nProvider safety checks:\n1. …]","options":["Approve","Deny"]}
```

The client replies with one of:
- `{"type":"extension_ui_response","id":"<same>","value":"Approve"}`
- `"value":"Deny"` or `"cancelled":true` → the tool fails with "Tool call denied by user: <name>"

If the call is aborted, the server sends `{"type":"extension_ui_request","id":"…","method":"cancel","targetId":"<id>"}`.

There is no timeout. `tool_execution_start` precedes the prompt. The `tool_approval_requested` / `tool_approval_resolved` events go to extensions only, not to the RPC stream.

**ACP:**
- **bash, edit (when it deletes or moves), delete, move:** the client gets `session/request_permission` with `toolCall{toolCallId,title,kind,status,rawInput,content,locations}` and options `allow_once` "Allow once", `allow_always` "Always allow", `reject_once` "Reject", `reject_always` "Always reject".
- **Everything else:** `unstable_createElicitation{mode:"form",sessionId,message:"Allow tool: …",requestedSchema:{type:"object",properties:{value:{type:"string",enum:["Approve","Deny"]}},required:["value"]}}`. This needs `elicitation.form`; without it the call is denied.
- An explicit `tools.approvalMode: yolo` skips both paths.

## 5. What `--mode rpc-ui` adds over `rpc`

(main.ts 1787–1789, 2087, 2313; sdk.ts)

1. `sessionOptions.hasUI = true`:
   - The `ask` tool is registered (`AskTool.createIf`).
   - `tui.reactions` applies.
   - LSP startup warmup runs.
   - MCP discovery is deferred.
   - Eager runtime model discovery is skipped.
   - Usage-reserve fallback may prompt instead of switching automatically.
2. The RPC UI context is passed through `setToolUIContext`, so tools and custom tools get `ctx.ui` and `hasUI` = true.
3. `PI_NO_PTY=1` is forced, so bash never uses a PTY.

`RpcExtensionUIContext` has no `askDialog`, so `ask` runs its fallback: per question a `select` (options plus "Other (type your own)", "Done selecting" for multi-select) and an `editor` for the custom answer. Headers, previews, notes and "Chat about this" are lost.

Both modes: `PI_NO_TITLE=1`, notifications off, `@file` arguments rejected.

## 6. Keybinding actions (app-keybindings.ts)

| Action | Default key | GUI mapping |
|---|---|---|
| app.interrupt | Esc | `abort` |
| app.clear | Ctrl+C | clear composer |
| app.exit | Ctrl+D | close |
| app.suspend | Ctrl+Z | n/a |
| app.display.reset | Alt+L | n/a |
| app.thinking.cycle | Shift+Tab | `cycle_thinking_level` |
| app.thinking.toggle | Ctrl+T | local view toggle |
| app.model.cycleForward | Ctrl+P | `cycle_model` |
| app.model.cycleBackward | Shift+Ctrl+P | client-side `set_model` |
| app.model.select | Alt+M | roles page |
| app.model.selectTemporary | Alt+P | picker → `set_model` |
| app.tools.expand | Ctrl+O | local |
| app.tools.toggleVisibility | Ctrl+Shift+O | local |
| app.editor.external | Ctrl+G | native editor |
| app.message.followUp | Ctrl+Q, Ctrl+Enter | `follow_up` |
| app.retry | F5, Alt+R | `/retry` |
| app.message.dequeue | Alt+Up, Shift+Up | gap |
| app.clipboard.pasteImage | Ctrl+V (Cmd+V on macOS) | attach |
| app.clipboard.pasteTextRaw | Ctrl+Shift+V | — |
| app.clipboard.copyLine | Alt+Shift+L | — |
| app.clipboard.copyPrompt | Alt+Shift+C | — |
| app.session.new / tree / fork / resume | unbound | — |
| app.agents.hub | Alt+A | hub |
| app.session.observe | Ctrl+S | hub |
| app.session.togglePath / toggleSort / rename / delete / deleteNoninvasive | Ctrl+P / Ctrl+S / Ctrl+R / Ctrl+D / Ctrl+Backspace | session-picker actions |
| app.tree.foldOrUp / unfoldOrDown | Ctrl/Alt+Left, Ctrl/Alt+Right | tree picker |
| app.plan.toggle | Alt+Shift+P | gap |
| app.history.search | Ctrl+R | — |
| app.stt.toggle | unbound (hold Space) | — |
| app.live.toggle | Ctrl+L | — |

There are also `tui.editor.*`, `tui.input.*` and `tui.select.*` editing actions.

Gestures: double-Esc (`doubleEscapeAction`: rewind), double-← (hub), `#<n>` issue/PR reference, `#` prompt actions, `/`, `!`, `!!`, `$`, `$$`. Vim mode is `tui.vimMode`.

## 7. CLI subcommands (cli-commands.ts)

**With `--json`:** agents, auth-broker, auth-gateway, bench, collab, config, dry-balance, find, gc, grievances, images (img), if-bench, install, models, plugin (plugins), ps, setup (with a component), skill (skills: search/info/token), ssh, stats, tiny-models, toks, ttsr, usage, worktree (wt).

**Without `--json`:** launch, acp, browser-relay, cleanse, commit, completions, compress, grep, gallery, git, join, login, say, clip, play, share, shell, read, render, stream, update, token, search (q, web-search), and the hidden `__complete`.

Sub-actions:
- config: list / get / set / reset / path / init-xdg
- plugin: install / uninstall / list / link / doctor / features / config / enable / disable / marketplace / discover / upgrade
- ps: list / info / logs / stop / kill / restart
- ssh: add / remove / list
- collab: list / link
- worktree: list / clear / add
- usage: invalidate / clients
- auth-broker: serve / token / login / logout / import / migrate / status / list
- skill: publish / version / tag / yank / deprecate / owner / token / import / install / update / uninstall / search / info

`--mode json` is the headless event stream.

## 8. No-daemon gap closure

**Companion extension** (`omp --mode rpc -e companion.ts`; explicit `-e` works even with `--no-extensions`):
- It registers `/gui:*` commands, which appear in the command list with source `extension` and run immediately even while the agent is streaming.
- It answers through `ctx.ui.notify(JSON)` or `setWidget` frames, each carrying a request id. Negotiate v2 framing for payloads over 1 MiB.

What it can reach:
- the live `settings` singleton (`pi.pi.settings`: get/set/setModelRole)
- `ctx.modelRegistry` and `ctx.models`, including `authStorage` [INFERENCE: which auth methods beyond `oauth.login` / `keys.source`]
- `ExtensionCommandContext`: `navigateTree`, `branch`, `switchSession`, `newSession`, `compact`
- `pi.setLabel`, `ctx.runEphemeralTurn` (for btw)
- session-listing exports
- forwarding of `tool_approval_*` events

What it cannot reach [INFERENCE]: plan / goal / vibe / loop, `/clear`, fork, pause, dequeue, subagent kill / revive — there is no AgentSession handle.

**Upstream RPC additions that would close the rest:**
- `set_plan_mode` plus plan-proposal UI
- `goal` / `vibe` commands
- `navigate_tree` (with summarize) and `set_label`
- `fork`, `reset_context`, `delete_session`
- `bash{excludeFromContext}` with streamed chunks; `python{code,excludeFromContext}`
- `get_settings_schema` / `set_setting`, and `set_model{role,persist}`
- `secret: true` on `input` frames, and `logout`
- `list_sessions`
- queue list/dequeue
- `subagent_command{steer|kill|revive}`
- an `ask_dialog` UI method
- a `tool_approval_requested` frame
- `pause`
