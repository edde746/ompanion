# Companion extension reach, omp v18.3.1 (`--mode rpc-ui -e`)

Evidence: source at tag v18.3.1 (`/tmp/oh-my-pi-18.3.1/packages/coding-agent/src` unless noted). Line numbers refer to that tag.

In the table, "yes" means the companion can call public methods on a live object. **"yes (rebuild)"** means the TUI logic lives in `InteractiveMode` (which does not exist in rpc-ui), so the companion has to recreate it from public session APIs. [INFERENCE] marks anything I did not verify in source.

## 1. What a companion can hold

| Handle | How to get it | Evidence |
|---|---|---|
| Host module namespace | `pi.pi`. The host `src/index.ts` includes sdk, agent-session, session-*, auth-storage, config/model-registry, the `Settings` class and `settings` singleton, tools (and through them the `goals` exports), task/executor, and `@oh-my-pi/pi-tui/theme` | loader.ts:28-29; index.ts |
| **Live main AgentSession** | `pi.pi.AgentRegistry.global().get(pi.pi.MAIN_AGENT_ID)?.session`. `MAIN_AGENT_ID` is "Main" | sdk.ts:863 export; default global registry and id: sdk.ts:1976-1977; registration: sdk.ts:3809-3811, 4646-4653; main.ts passes no private registry; tui agent-hub-types.ts:5 |
| `ctx.session` / `getSession` | **Do not exist** | types.ts:399-497; runner.ts:1241-1310 |
| SessionManager (writable) | `ctx.sessionManager` is the real `SessionManager` object, only typed read-only. Cast it to call `appendLabelChange`, `appendModeChange`, etc. | runner.ts:620, 1249 |
| Auth store and model registry | `ctx.modelRegistry` → `.authStorage` (`keys`, `oauth`, `credentials`) | runner.ts:1250; rpc-mode.ts:1633; selector-controller.ts:1913-1924 |
| Settings | `session.settings` or `pi.pi.settings`; schema via `import("@oh-my-pi/pi-coding-agent/config/registry")` | index.ts; registry.ts:795-802 |
| Subagent registry and lifecycle | `AgentRegistry` via `pi.pi`; `AgentLifecycleManager` via the deep import `registry/agent-lifecycle` | package.json:433; agent-lifecycle.ts:95 |
| IrcBus | Not a package export and not in `pi.pi` (irc/bus.ts:27). Not needed: use lifecycle + `session.prompt` | collab/host.ts:1063-1071 |
| Tool/extension UI object | `ctx.ui` is the single `RpcExtensionUIContext`. The same object is handed to tools | runner.ts:727; rpc-mode.ts:1009-1031; tools/context.ts:47-48 |
| Controllers | Every controller needs an `InteractiveModeContext` (e.g. cleanse-command-controller.ts:34), so none are usable headless. Headless references: ACP plan mode (acp-agent.ts:1851-1974) and collab-host agent control (host.ts:1043-1090) | |

Which deep imports work depends on how omp is installed:
- **Compiled binaries and npm bundles:** only named-wildcard subpath exports are available; the root `./*` catch-all is skipped (legacy-pi-virtual-module.ts:150-158). Available: `config/*`, `session/*`, `modes/*`, `modes/controllers/*`, `plan-mode/*`, `registry/*`, `slash-commands/*`, `task/*`, `tools/*` (package.json:161-489). Not available: `cleanse`, `irc`, `vibe`, `advisor`, and pi-tui `overlays/*` (pi-tui only exports `./*`, tui/package.json:93).
- **Module identity:** subpath imports should resolve to the same host module instance [INFERENCE: dedup by path].

## 2. Reply path, size limits and feature detection

**App → companion**
- Send RPC `prompt` with `/ompx <verb> <json>`. The RPC prompt path tries skills first, then builtins that have a `handle` (acp-builtins.ts:60-66), then `session.prompt`. `session.prompt` runs the extension command before any streaming check (agent-session.ts:6651-6655, 7329-7355).
- The response is sent immediately, then `prompt_result{agentInvoked:false,status:"completed"}` when the handler finishes (rpc-prompt-results.ts:93-96, 281-296).
- If the handler throws, the host emits an `extension_error` frame with `extensionPath:"command:<name>"` (agent-session.ts:7346-7352).
- Correlate calls with a request id carried in the JSON arguments.

**Fast path (private field):**
- The companion keeps a pending "mailbox" request open in `ctx.ui.pendingRequests`.
- The app replies with `{type:"extension_ui_response",id,value:<json>}`. Only `type` and `id` are checked, and the whole frame is passed to `resolve` (rpc-mode.ts:253-263).
- Response frames are control frames: they are handled immediately and never wait in the command queue.

**Companion → app**
- **Public:**
  - `ctx.ui.notify(msg)` (rpc-mode.ts:882-892)
  - `setWidget(key, string[])` (909-921)
  - `setStatus` (894-904)
  - `editor(title, prefill)` as a request/response string exchange (600-658)
  - `session.emitNotice(level, msg, "ompx")` → `notice` frame (agent-session.ts:2786-2788; agent-session-events.ts:65)
- **Private:** `ctx.ui.output(frame)` can send any frame, e.g. `extension_ui_request{method:"ompx.*"}`. `output` and `pendingRequests` are TypeScript `private` constructor parameters (rpc-mode.ts:832-835), so they are ordinary properties at runtime [INFERENCE: TypeScript parameter-property emit].
- `set_event_filter` only filters session events (rpc-session-events.ts:30-34). `extension_ui_request` frames are unaffected; `notice` frames are affected.
- `--no-ui` turns off every `ctx.ui` frame (rpc-mode.ts:760-761, ~1031). It is only allowed with `--mode rpc` anyway (main.ts:1743-1746).

**Push sources**
- `pi.on` events (types.ts:1253-1308): session_*, agent/turn/message/tool_*, tool_call, tool_result, tool_approval_*, input, user_bash, user_python, goal_updated, credential_disabled, mcp_notification, before_subagent_spawn.
- `session.subscribe`.
- `AgentRegistry.onChange` (agent-registry.ts:352).

**Size limits**
- Every output frame goes through `RpcFrameEncoder`.
- On protocol v2, a frame over 1 MiB is split into `rpc_chunk` frames of 256 KiB, up to 64 MiB in total (rpc-frame.ts:6-10, 97-124).
- On v1, strings in an oversized frame are cut down (rpc-frame.ts:244-262), so negotiate v2 (rpc-mode.ts:1121-1125).
- Inbound frames are not reassembled from chunks: the server reads one JSON line per frame (rpc-input.ts:47-68; the decoder exists only in rpc-client.ts:16,365). The line length appears unbounded (utils/stream.ts:15) [INFERENCE].

**Feature detection**
- `get_available_commands` lists extension commands with `source:"extension"`. It hides only names reserved by builtins that have a `handle`, and colon-prefixed names that shadow them (available-commands.ts:73-84; acp-builtins.ts:13-31).
- Frames are re-sent as `available_commands_update` (rpc-mode.ts:~1097-1105).
- TUI-only builtin names (plan, goal, vibe, loop, queue, btw, clear, fork, tree, pause, settings, setup, skills, agents, extensions, tan, omfg, cleanse, login, logout, …) are **not reserved in RPC**. A companion can register them, and typing `/plan` in the app then reaches the companion (runner.ts:1196-1204).
- Name the main command without a colon, e.g. `ompx`.
- Version gate: `pi.pi.VERSION`.

## 3. `ask` fidelity and approvals

- The native `ask` tool calls `context.ui.askDialog` if it exists. The request carries `id`, `question`, `header`, `options{label,description,preview}`, `multi` and `recommended`. The result shape is `{kind:"submit",results[{id,question,options,multi,selectedOptions,customInput,note,timedOut}]}`, or `{kind:"chat"}`, or `undefined` for cancel (ask.ts:926-1000; tui ask-dialog.ts:20-60).
- `RpcExtensionUIContext` in 18.3.1 has no `askDialog` (rpc-mode.ts:831-1005), so without the companion `ask` falls back to `select`/`editor` (ask.ts:485-521). From omp 18.4.9 the class declares `askDialog` as a getter without a setter: it returns omp's own RPC ask dialog (`extension_ui_request` method `ask`) once a host sent `set_ask_dialog`, and `undefined` (the same fallback) before.
- **Fix (in place):** the companion installs its own `askDialog` (a companion `ask` request) as an own property of the raw UI object with `Object.defineProperty`, which shadows 18.4.9+'s getter; a plain assignment would throw in the strict ESM bundle. It never sends `set_ask_dialog`, so omp's native ask dialog stays off. Tools receive the same object (tools/context.ts:37).
- **Alternative:** re-register a tool named `ask` and fall back to the native one through `ctx.invokeTool` (types.ts:522-540).
- `tool_approval_requested` and `tool_approval_resolved` are notifications only (types.ts:936-952).
- A `tool_call` handler can block a tool call, so the companion can run its own richer approval exchange before the tool runs. The exact `ToolCallEventResult` shape is [INFERENCE] (it lives in shared-events).

## 4. 18.3.1 RPC additions vs the gaps

| Addition | Closes? |
|---|---|
| `open_session{sessionDir}` resumes the latest session in a directory or starts a new one. Needs persistence (rpc-mode.ts:488-510, 1259-1270) | Covers switching project directory. Does **not** list sessions or give titles |
| `set_event_filter` (1380-1389) | Only reduces noise. Keep `notice` in the filter if the companion uses it |
| `prompt_result` and `session_settled`, `get_state.isSettled` / `hasPendingAsyncWork` (rpc-session-settle.ts:21-89; rpc-mode.ts:1287-1288) | **Loop mode can be done entirely in the app**: re-send the prompt on each `prompt_result`. They also give plan/goal continuation logic reliable turn boundaries |
| `--no-ui` | Not compatible with the companion (see §2) |
| `get_state.queuedMessageCount` | Gives a count only; listing and dequeue still need the companion |

## 5. Item-by-item

| Item | Reachable | Exact API path (file:line) | What the companion must do | Risk |
|---|---|---|---|---|
| Settings read/write with metadata (type, enum, default, tab/group, description; scope) | yes, except project writes | `registry.all()` / `lookup` (registry.ts:795-802). Per setting: `type`, `enumValues`, `default`, `ui{tab,group,label,description,warning,options,secret}`, `isCredential` (491-514); `get`/`layered` (545-556); `provenance(scope)` = env/runtime/overlay/project/global/default (764-767); `set` = global persisted, `override` = session-only, `unset`, `clearOverride` (710-743). Raw layers: `settings.getGlobalSettings()` / `getProjectSettings()` (settings.ts:1386-1400) | Turn the definitions into JSON: drop the `validate`/`normalize`/`env.parse` functions, redact credentials, and fill `options:"runtime"` choices (e.g. themes). `cfg://` writes are refused in RPC (cfg-protocol.ts:6-12; main.ts:2139). `omp config list --json` gives only value/type/description (config-cli.ts:203-221) | Medium: the registry changed in 18.3.1. Writes persist to config.yml and can trigger settings effects |
| Persist model roles | yes | `settings.setModelRole(role,id)` (settings.ts:1559); `setProjectModelRole` / `clearProjectModelRole` (1600-1612); `getModelRoles` / `getModelRoleProvenance` (1649-1669) | Thin wrapper | Low |
| List sessions across all projects, with titles | yes | `pi.pi.listAllSessions()` (session-listing.ts:651) → `SessionInfo{path,id,cwd,title,parentSessionPath,created,modified,messageCount,assistantTurns,status}` (31-53); `SessionManager.listAllForPicker()` (selector-controller.ts:1602) | Drop `allMessagesText`, page the results, add pins (`loadPinnedSessionIds`, module path [INFERENCE]) | Low |
| Tree navigate with branch summary; labels | yes | `ctx.navigateTree(id,{summarize})` → `session.navigateTree` (runtime-init.ts:140-143). Labels: **`pi.setLabel(entry,label)` is broken** — it only sets the extension label (loader.ts:245-247) — so call `ctx.sessionManager.appendLabelChange(id,label)` (runtime-init.ts:113-115). The tree is already available via RPC `get_tree` (rpc-mode.ts:1337-1342) | The summary step costs a model call. The `session_before_tree` hook can supply a custom summary | Low-medium |
| Fork session | yes | `session.fork()` (command-controller.ts:1144-1160). Existing RPC `branch` covers fork-from-entry | Refuse while streaming; afterwards re-fetch `get_state` | Low |
| /clear (reset in place) | yes | `session.resetSessionContext()` → `{droppedCount}`. Abort compaction first with `abortCompaction` and wait on `isCompacting` (command-controller.ts:1105-1134). In 18.3.1, `/clear` means this (builtin-lifecycle.ts:224-232); `/new` = RPC `new_session` | App re-fetches messages afterwards | Low |
| Delete session | yes | Current session: `session.newSession({drop:true})` (command-controller.ts:1136-1142). Any session: `new pi.pi.FileSessionStorage().deleteSessionWithArtifacts(path)` (selector-controller.ts:1590-1594) | Never delete the file the session currently has open (the TUI detaches first) | Medium (destructive) |
| API-key login (set credential) | partial | `ctx.modelRegistry.authStorage`. `keys.setRuntime(provider,key)` is runtime-only (main.ts:2320). The persistent write method name is **not verified** [INFERENCE: a `credentials` store API]. Then `modelRegistry.refreshProvider(p,"online")` (rpc-mode.ts:1694) | Collect the key through a private request (RPC `login` refuses secret prompts, rpc-mode.ts:1672-1677) | Medium |
| Logout / list accounts / account pin | yes | List: `authStorage.credentials.reload()` / `list(p)`, `oauth.identity(p,sid)`, `keys.source` / `describe` + `toLogoutAccounts` (selector-controller.ts:1913-1924; helpers/logout.ts:79-100). Remove call is in the collapsed `#handleCredentialLogout` body [INFERENCE: remove by credential id], then `refreshProvider` (1886). Pin: `session.listCurrentProviderOAuthAccounts()` + `toSessionPinAccounts` + `session.pinCurrentProviderOAuthAccount(id)` (builtin-session.ts:113-173). A text-only version already works over RPC as `prompt "/session pin …"` (231-266) | Return structured rows | Medium |
| /btw ephemeral side turn | yes | `ctx.runEphemeralTurn({promptText, history, conversationKey, onTextDelta, tools?})` (types.ts:470-476; runner.ts:1262-1291; btw-controller.ts:607-610). History: `session/btw-history` (btw-controller.ts:5-12) | Stream `onTextDelta` as custom frames; persist BTW history the way the TUI does [INFERENCE] | Low-medium |
| Extensions control center (list, enable/disable) | partial | List: `session.extensionRunner.getExtensionPaths()` / `getLoadedExtensions()` (runner.ts:733, 914). Disabled ids use the `extension-module:<name>` form (loader.ts:533-551); the settings key name is [INFERENCE]. Live suspend (`#suspendedExtensions`, runner.ts:766) is private | Persist the disable in settings, then `ctx.reload()` (runtime-init.ts:148-150) or restart | High |
| Agents dashboard (per-agent model/advisor/prewalk overrides) | partial | Agent model overrides are a setting (`cfgTaskAgentModelOverrides.override`, selector-controller.ts:716-719; find its id via `registry.all()`). `pi.pi.discoverAgents` (task/index.ts:121). `session.toggleAdvisorEnabled` / `getAdvisorStats` (builtin-collaboration.ts:83; command-controller.ts:480); `armPrewalk` / `restartPrewalk` (builtin-modes.ts:688-713). `advisor/` is not a package export | Rebuild the dashboard as settings plus session calls | Medium-high |
| Prompt history search | yes | Deep import `session/history-storage`: `HistoryStorage.open()`, `search`, `getRecent`, `add` (history-storage.ts:134, 199, 212, 226) | RPC prompts are probably not recorded [INFERENCE]; add them from `pi.on("input")` (source `"rpc"`, types.ts:866-871) | Low-medium |
| Theme resolution (resolved palette) | yes | `pi.pi.getResolvedThemeColors(name?)` → token→hex (theme.ts:743-771); `getCurrentThemeName` (108); `getAvailableThemes` / `WithPaths` / `getThemeByName` (14); `isLightTheme` (776). The RPC `ctx.ui` theme methods are stubs (rpc-mode.ts:975-988) | Return palette JSON; change the theme through settings | Low |
| Plan mode toggle + review/approval | yes (rebuild) | `setPlanModeState({enabled,planFilePath,workflow,reentry})` (agent-session.ts:6106), `setPlanProposalHandler` (2419), `preparePlanForReview` (1357), `sendPlanModeContext`, `setActiveToolsByName` / `restoreNonMCPToolPresentation` / `getMountedXdevToolNames`, `setPlanReferencePath` / `markPlanReferenceSent`, `runModeExitTeardown`, `sessionManager.appendModeChange` (interactive-mode.ts:4216-4450). Approval steps: 4904-5093. Headless model: acp-agent.ts:1851-1974 using `plan-mode/*` (`resolveApprovedPlan`, `autosaveApprovedPlan`) | Register `plan` and `plan-review` commands. The proposal handler sends an `ompx.planReview` request with the plan text and approve / clear / compact / refine choices. Recreate: tool snapshot and restore, plan model role, compact with `internalGuidance` (types.ts:360-372), synthetic follow-up prompt (prompt templates are internal [INFERENCE: `./prompts/*` imports]), and restore the mode on `session_start`/`session_switch` from `buildSessionContext().mode` (4131-4213) | **High**: large amount of private logic that churns between releases |
| Goal mode (set/show/pause/resume/drop/budget) | yes (rebuild) | `session.goalRuntime.createGoal` / `resumeGoal` / `pauseGoal` / `dropGoal` / `onThreadResumed` / `clearAccounting` (interactive-mode.ts:4470-4474, 5618, 5642); `setGoalModeState` / `getGoalModeState` / `sendGoalModeContext` (agent-session.ts:6120-6287); `goal_updated` event; add the "goal" tool (interactive-mode.ts:4465-4471) | Continuation after each yield is private to InteractiveMode (3964-3968): re-prompt on `prompt_result`. Budget API name [INFERENCE]. On completion, write `appendModeChange("none")` + `goal-completed` entry (4494-4504) | High |
| Guided-goal | partial | `handleGuidedGoalCommand` (interactive-mode.ts:5453). Body not read [INFERENCE: interview prompt, then createGoal] | Send the interview prompt with `pi.sendUserMessage`, then set the goal | High |
| Vibe mode | partial; compiled builds: probably no | `session.setVibeModeState`, `removeVibeToolsPreservingActive` (interactive-mode.ts:4115-4118, 5291-5380). Also needs `VibeSessionRegistry.global()` (vibe/runtime.ts:253-260), which is not a package export; whether `tools/vibe` re-exports it is [INFERENCE] | Rebuild enter/exit and worker cleanup | High |
| Loop mode | yes, **companion optional** | All state lives in InteractiveMode (interactive-mode.ts:2624-2653); helpers in `modes/loop-limit.ts` and `modes/loop-condition.ts` | App (or companion) re-sends the loop prompt on each `prompt_result` / `agent_end` with `yielded`; `--while` / `--until` via `pi.exec` or SSH | Low |
| /pause (freeze all agents) | yes | `runPauseScreen` (tui/src/overlays/pause-screen.ts:176-198) only wraps `agentPauseGate.pause()` / `resume()`. The gate is `AgentPauseGate` in agent/src/pause.ts:25-107, exported from the `@oh-my-pi/pi-agent-core` root (agent/src/index.ts:11-12), which the compiled binary bundles with no root shim (coding-agent/scripts/legacy-pi-virtual-module.ts:18,125-126). `agentLoop` parks on it before each model call (agent-loop.ts:1283) and before each tool starts (3220) | Import `agentPauseGate`; expose `pause`, `resume`, `paused`, `pausedAt`; push `onChange`. Process-global = one rpc process = one session | Low: small, stable surface |
| Queue list + dequeue | yes | `session.getQueuedMessages()` → `{steering, followUp}` (agent-session.ts:8183); `popLastQueuedMessage()` (8195); `clearQueue()` (8151); `/queue` = RPC `follow_up` | Push a queue snapshot on message and agent events | Low |
| Subagent steer / kill / revive | yes | Collab recipe (host.ts:1043-1085): `AgentLifecycleManager.global().ensureLive(id)` → `s.prompt(t,{streamingBehavior:"steer"})`; kill = `ref.session.abort()` + `release(id,ref,{tombstone:true})`; revive = `ensureLive`. The persisted reviver is installed in RPC too (main.ts:2307-2319) | Skip advisor refs; stream the roster from `onChange` | Medium |
| User python (`$` / `$$`) | yes | `session.executePython(code, onChunk, {excludeFromContext})` (command-controller.ts:1480-1500) | Stream chunks as frames; show the final result | Low |
| User bash with excludeFromContext and streaming (`!!`) | yes | `session.executeBash(cmd, onChunk, {excludeFromContext, useUserShell:true})` (command-controller.ts:1405-1423); cancel with `session.abortBash()`. RPC `bash` passes only the command (rpc-mode.ts:1531-1534) | Leave out `pty` (rpc-ui forces PI_NO_PTY, main.ts:1838-1840). The TUI's cd → session relocate step would need recreating | Low |
| /tan, /omfg, /cleanse | omfg yes; tan partial; cleanse **no** in compiled builds | omfg: `runEphemeralTurn` + `modes/controllers/omfg-rule` + `session.ttsrManager.addRule` (omfg-controller.ts:157, 291). tan: `sdk` / `createSubagentSettings` / `createMCPProxyTools` / `AgentRegistry` (tan-command-controller.ts:6-16), all in `pi.pi`. cleanse: `runCleanse` from `src/cleanse` (cleanse-command-controller.ts:6, 87-99) | Rebuild the omfg and tan flows. Cleanse: use the `omp cleanse` CLI one-shot instead | High |
| /setup provider wizard | partial | `runProviderSetupWizard(InteractiveMode)` (interactive-mode.ts:7184-7187) | Rebuild from RPC `get_login_providers` / `login`, the authStorage key path, and web-search settings | Medium-high |
| /skills registry | partial | TUI-only (builtin-skills.ts:65-79). Registry client not located [INFERENCE]; `session.refreshSkillsAndCommands()` (rpc-mode.ts:1091). `omp skill` CLI exists | Wrap the client if it is importable, otherwise use the CLI | Medium |
| /advisor configure | yes via settings; toggle via RPC text | `/advisor` has a `handle` (builtin-collaboration.ts:60-123); advisor settings live in the registry (Model tab, "Advisor" group) | Same as the settings row | Medium |
| Structured context breakdown | yes | `computeSessionContextBreakdown(session,{snapcompactSavings:true})` (command-controller.ts:705-712; module path [INFERENCE]). RPC `/context` returns text only (builtin-session.ts:481-484) | Serialize the breakdown | Medium |
| Full-fidelity `ask` (headers, previews, notes, multi-select) | yes | Set `ctx.ui.askDialog` (§3) | Custom request/response via the private fields | Medium |
| /agents | partial | = agents dashboard row | | Medium-high |
| /extensions | partial | = control center row | | High |

## 6. Unreachable even for a companion

1. **`/cleanse` in compiled or bundled installs.**
   - `runCleanse` is in `src/cleanse`, which is not a package export, and bundled builds leave out the root `./*` catch-all (legacy-pi-virtual-module.ts:150-158).
   - Its only in-process caller is `CleanseCommandController`, which needs an `InteractiveModeContext` (cleanse-command-controller.ts:34).
   - Workaround: the `omp cleanse` one-shot.
2. **Vibe worker registry in compiled installs (probable).** `VibeSessionRegistry` (vibe/runtime.ts:253) is not in the package exports. Whether it is re-exported through `pi.pi` is unverified.
3. **Writing arbitrary settings to the project config.**
   - `Settings.writeValue` only accepts "global" or "override" (settings.ts:818); only model roles have a project writer (1600).
   - Workaround: edit `.omp/config.yml` over SFTP. The rpc-ui settings watcher applies the change live (main.ts:2362-2367).
4. **TUI component UIs and synchronous editor state.**
   - RPC stubs `custom()`, component widgets, header/footer, and theme get/set (rpc-mode.ts:909-988).
   - `getEditorText()` always returns "" (963-967).
   - Anything built as a pi-tui component must be rebuilt as data in the app.
5. **Mode state held by InteractiveMode.** Plan, goal, vibe and loop flags plus goal continuation live in InteractiveMode, which does not exist in rpc-ui. They can only be recreated, never called. Behaviour will drift from the TUI across releases.
6. `/pause` was listed here first; a follow-up read found the gate, and it is reachable (see its row).

**Risk notes**
- The strongest channels rely on the TypeScript-private fields `ctx.ui.output` and `ctx.ui.pendingRequests`, and on monkeypatching `askDialog`. Guard every use with a feature check and fall back to `notify` / `editor`.
- All deep imports must use exported subpaths and be re-verified for each newly supported omp version.
