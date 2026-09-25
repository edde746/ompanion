# omp integration options: no-daemon RPC route and daemon delivery

Evidence: local clones `/tmp/oh-my-pi-18.3.0` (= installed omp 18.3.0) and `/tmp/oh-my-pi` (main, 18.3.1), omp:// docs, GitHub issues, Bun and T3 Code docs. Unverified claims are marked [INFERENCE].

## 1. Bottom line
- **No daemon is viable for chat parity.** RPC (18.3.0) covers:
  - prompt / steer / follow_up / abort, queue modes, compaction, retry;
  - model, thinking and fast mode;
  - new, switch and branch sessions; tree and entries; paged messages;
  - subagents, todos, bash, HTML export, handoff, OAuth login;
  - host tools and host URI schemes.
- **Not reachable over RPC**:
  - settings, session listing, API-key login, theme, in-file tree navigation;
  - plan / goal / vibe / loop modes;
  - the extensions / agents / hub dashboards;
  - `/btw`, `/clear`, `/delete`, `/fork`, `/logout`, `/skills`.
- **CLI `--json` and SFTP** close part of that. A **companion extension** loaded into each rpc process closes nearly all the rest (plan/goal/vibe/loop mode toggles excepted: no extension API found), using only the existing RPC frames.
- **Main no-daemon risk:** closing stdin disposes the session, and disposal aborts the active turn. Session lifetime is tied to the SSH channel.
- **Upstream has no `omp serve`.** #5742 is open with no maintainer decision. Upstream's RPC direction is per-process: `open_session`, `prompt_result`, `session_settled` and `--no-ui` arrived in 18.3.1.

## 2. No-daemon surface inventory

### 2.1 RPC commands, 18.3.0 installed (`rpc-types.ts:26-92`)
- **Protocol:** `negotiate_protocol` (v2 is lossless `rpc_chunk`, up to 64 MiB; v1 frames are capped at 1 MiB).
- **Prompting:** `prompt` (with `streamingBehavior`), `steer`, `follow_up`, `abort`, `abort_and_prompt`, `new_session`.
- **State:**
  - `get_state`, `set_fast_mode`, `get_available_commands`, `get_entries(since)`, `get_tree`, `set_todos`;
  - `set_host_tools`, `set_host_uri_schemes`;
  - `set_subagent_subscription`, `get_subagents`, `get_subagent_messages`.
- **Model:** `set_model`, `cycle_model`, `get_available_models`.
- **Thinking:** `set_thinking_level`, `cycle_thinking_level`, `get_available_thinking_levels`.
- **Queue:** `set_steering_mode`, `set_follow_up_mode`, `set_interrupt_mode`.
- **Compaction:** `compact`, `set_auto_compaction`.
- **Retry:** `set_auto_retry`, `abort_retry`.
- **Bash:** `bash`, `abort_bash`.
- **Session:** `get_session_stats`, `export_html`, `switch_session`, `branch`, `get_branch_messages`, `get_last_assistant_text`, `set_session_name`, `handoff`.
- **Messages:** `get_messages`, `get_messages_page`.
- **Login:** `get_login_providers`, `login`.

Added on main, 18.3.1 (`/tmp/oh-my-pi/.../rpc-types.ts:35,47`; `docs/rpc.md`):
- `open_session(sessionDir)`: the runtime equivalent of `--session-dir <dir> --continue`;
- `set_event_filter`;
- `prompt_result{status, error, sessionSettled}` and `session_settled` frames;
- `get_state.isSettled` and `hasPendingAsyncWork`;
- `--no-ui` (suppresses `extension_ui_request` frames except the login flow).

### 2.2 `rpc` vs `rpc-ui` (18.3.0 `main.ts`)
- `rpc-ui` sets `PI_NO_PTY=1` (1787) and `hasUI = isInteractive || rpc-ui` (2087).
- It passes `setToolUIContext` to `runRpcMode` only in `rpc-ui` (2313). So only rpc-ui gets the `ask` tool (`AskTool.createIf` requires `hasUI`; omp://tools/ask.md) and tool-level UI dialogs.
- Both modes give extensions `RpcExtensionUIContext` (`rpc-mode.ts:1070-1089`).

### 2.3 Extension UI over RPC (`rpc-mode.ts:886-1058`)
- **Supported:**
  - `select`, `confirm`, `input`, `editor` (request/response);
  - `notify`, `setStatus`, `setWidget` (string[] only), `set_editor_text` (fire-and-forget);
  - `setTitle` only when `PI_RPC_EMIT_TITLE=1`.
- **No-ops:** `custom()`, `setFooter`, `setHeader`, `setEditorComponent`, `addAutocompleteProvider`, `setWorkingMessage`, `onTerminalInput`. `getEditorText()` returns `""`; `getAllThemes()` returns `[]`; `setTheme` fails.
- Consequence: extension TUI components and custom tool/message renderers can't be shown.

### 2.4 Slash commands over RPC
- Dispatch order (`rpc-mode.ts:1159-1233`): skill prompt, then text-capable built-in (output goes to `command_output`, plus `session_info_update` / `config_update`), then `session.prompt`.
- Inside `session.prompt`, extension commands run **first and immediately, even while streaming**, with no transcript entry (`agent-session.ts:6411-6418`; omp://slash-command-internals.md §5, §8).
- **Text-capable (reachable), verified in source:**
  - `advisor`, `export`, `trace`, `dump`, `share`, `force`, `ssh`, `fresh`, `compact`, `shake`, `handoff`;
  - `marketplace`, `plugins`, `reload-plugins`, `security`, `todo`, `session`, `jobs`, `usage`, `stats`, `changelog`;
  - `tools`, `context`, `mcp`, `retry`.
  - Likely also: `memory`, `rename`, `move`, `wt`, `model`, `fast` (they carry `acpDescription`, which in the verified commands accompanies a text `handle`; handlers not checked).
- **TUI-only** (#13281, tested on 18.3.1; spot-checked in 18.3.0 source):
  - `agents`, `branch`, `btw`, `cleanse`, `clear`, `collab`, `copy`, `debug`, `delete`, `exit`, `extensions`, `fork`, `git`;
  - `goal`, `guided-goal`, `hotkeys`, `hub`, `join`, `leave`, `live`, `login`, `logout`, `loop`, `new`, `omfg`, `open`;
  - `pause`, `plan`, `plan-review`, `queue`, `quit`, `record`, `resume`, `settings`, `setup`, `tan`, `tree`, `update`, `vibe`;
  - plus `skills` (`builtin-skills.ts:79`, both versions).
- TUI-only names are not advertised over RPC and **fall through to the model as a paid turn**.
- `command_output` is ANSI-formatted and ignores `NO_COLOR` (#13281).

### 2.5 CLI `--json` (18.3.0 `src/commands/*`)
- `config` actions: `list`, `get`, `set`, `reset`, `path`, `init-xdg`.
  - `list --json` returns `{path: {value | redacted, type, description}}`, with no enum options, defaults or tab/group.
  - `set` writes the **global** layer only (`Settings.set` "Updates global settings", `settings.ts:724-728`).
- `plugin` actions: `install`, `uninstall`, `list`, `link`, `doctor`, `features`, `config`, `enable`, `disable`, `marketplace`, `discover`, `upgrade`, with `--scope user|project`.
- `models` actions: `ls`, `find`, `refresh`, `<provider>`.
- Also `--json`: `usage`, `agents`, `skill` (search/info/token), `collab`, `worktree`, `ssh`, `ps` (`--all`, `--plain`, `--dir`, `--global`), `stats`, `setup --check`, `gc`, `grievances`, `images`, `install`, `tiny-models`, `toks`, `ttsr`, `find`, `bench`, `auth-broker`, `auth-gateway`.
- **Missing:** no `mcp` CLI and no sessions CLI. The hidden `omp __complete sessions` prints `id\ttitle` TSV for the current cwd only (`commands/complete.ts`).
- `omp login [provider]` uses readline on stdin/stdout, opens the browser **on the host** and is OAuth-only (`cli/login-cli.ts`). Remote use needs a PTY plus callback-port forwarding (compare `auth-broker login --via` with `ssh -L` in omp://auth-broker-gateway.md).

### 2.6 SFTP-only reads (omp://session.md)
- Sessions: `~/.omp/agent/sessions/<encoded-cwd>/<ts>_<id>.jsonl`. Current files start with a fixed 256-byte title slot, then the header line (version 3). Blobs are at `~/.omp/agent/blobs/<sha256>`.
- Other roots to cover:
  - profiles: `~/.omp/profiles/<name>/agent`;
  - XDG layouts: `omp config init-xdg`;
  - `PI_CODING_AGENT_DIR` and `--session-dir`.
- `index.ts` exports redis/sql session storage modules; a remote backend, if configured, bypasses disk [INFERENCE: config mechanism not checked].
- Never read `agent.db` (credential store).

## 3. Parity gap matrix
| Feature | RPC / rpc-ui | CLI `--json` / SFTP | Companion ext | Upstream fix |
|---|---|---|---|---|
| Chat, steer, queue, abort | yes | – | – | – |
| List sessions (all projects) | no | SFTP headers; `__complete` (cwd, TSV) | yes `pi.pi.SessionManager.list` | `list_sessions` |
| Resume / open | yes `switch_session` (+`open_session` 18.3.1) | – | – | – |
| In-file tree nav (`/tree`) | no (RPC `branch` makes a new file, `agent-session.ts:10048-10060`) | – | yes `ctx.navigateTree(id, {summarize})` (types.ts:540-576) | `navigate_tree` |
| `/fork`, `/clear`, `/delete` | no | delete: SFTP + artifacts | partial (`ctx.branch` / `newSession`) [INFERENCE] | commands |
| Model roles | no (`set_model` is per session) | `omp config set modelRoles…` (global) | yes Settings | `set_setting` |
| Settings read/write | no | `omp config` (global; running 18.3.0 sessions don't reload: `reloadFromDisk` only called at subagent spawn; main adds `fs.watch`, `settings.ts:1046`); project YAML via SFTP | yes live `pi.pi.settings` + `config/settings-schema` | `get_settings_schema` / `get_settings` / `set_setting` (#13281) |
| OAuth login | yes RPC `login` (non-secret prompts only) | `omp login` via PTY | yes `authStorage.oauth.login` | – |
| API-key login | no secret prompts rejected (omp://rpc.md) | `models.yml` apiKey / env via SFTP | yes `credentials.set` / `upsert` (packages/ai/src/auth/types.ts:786-797) | secret-input frame |
| Logout / accounts | no | `omp usage --json` | yes `credentials.remove` / `list` / `snapshot` | – |
| Plugins / marketplace | yes text | yes `omp plugin --json` | – | structured |
| MCP | yes `/mcp` text | no | yes discovery / mcp modules | structured |
| Skills registry | no | yes `omp skill` | – | – |
| Extension Control Center | no | SFTP (`disabledExtensions`) | yes discovery `loadCapability` | `get_extensions` |
| Agents hub | no | `omp agents --json` | yes | `get_agents` |
| Plan / goal / vibe / loop | no (#8171) | launch flag `--plan-yolo` only | unknown no ctx API found | mode commands |
| `/btw` | no | – | yes `ctx.runEphemeralTurn` | – |
| Context breakdown | `/context` (ANSI) | – | yes `ctx.getContextUsage()` | structured output |
| Theme | no `setTheme` fails | app ships palettes | yes `modes/theme/theme` | `get_theme` |
| Extension custom UI / renderers | no (string[] widgets only) | – | partial: render pi-tui components to ANSI lines [INFERENCE] | – |
| Approvals / ask | via `extension_ui` select; `ask` in rpc-ui | – | – | typed approval frame (#5742 comment) |
| Live TUI sessions | no | `omp collab list --json` / `link` | – | – |
| Terminal / files | RPC `bash` pollutes transcript | SSH PTY / SFTP | – | – |
| Update omp | no `/update` TUI-only | `omp update` / `install.sh --ref` | – | – |

## 4. Companion extension over the existing RPC channel

Feasibility evidence:
- Every extension receives `pi.pi` = `import * from src/index` of the **host process** (`loader.ts:29,192,451`; `types.ts:1233`). That exports:
  - Settings / settings, model-registry, sdk (`createAgentSession`, discovery);
  - auth-storage, session-manager / listing / loader;
  - skills, extensions, theme utilities.
- In the compiled binary, `@oh-my-pi/pi-coding-agent` (root plus named and recursive-wildcard subpaths) resolves to the host bundle (`legacy-pi-compat.ts` `USE_BUNDLED_PI_MODULES`, `PI_PACKAGE_NAMES`; `scripts/legacy-pi-virtual-module.ts`).
  - Root-level subpaths like `/sdk` and `/thinking` are excluded (catch-all `./*`); use the root import or `pi.pi`.
  - The root import's `AuthStorage` is a legacy shim class (`legacy-pi-coding-agent-shim.ts:1446`); use `ctx.modelRegistry.authStorage`.

Protocol sketch:
- **Launch:** `omp --mode rpc-ui -e /abs/companion-<ver>.js [--no-session for control]`.
  - Don't use `--trusted-extension`: it is an exact allowlist that disables user extensions (`main.ts:1597-1621`) and can't be combined with `-e` (`args.ts:321-322`).
  - Don't use `--no-ui` (18.3.1): it suppresses the reply frames.
- **Request:** `{"id":"r1","type":"prompt","message":"/omp-app {json incl corr}"}` returns a success response, then `prompt_result{agentInvoked:false}` (`rpc-mode.ts:235`).
- **Reply:** `ctx.ui.setStatus("omp-app:<corr>", json)` or `notify(json)` arrives as `extension_ui_request`; the host filters the key prefix. Frames are ≤1 MiB on v1; negotiate v2 for bigger payloads.
- **Companion-initiated request:** `ctx.ui.input` / `editor` / `select` round-trips (e.g. to enter a secret).
- **Push:** the companion subscribes to events (`credential_disabled`, `tool_approval_*`, `session_*`) and emits status frames.

Limits:
- Runs with omp's privileges and in omp's process; handler throws surface as `extension_error`.
- Manual `/compact` makes prompts wait until the compaction finishes (`agent-session.ts` `#prompt`).
- It depends on internal APIs that change every release, so build and pin one companion per omp version and feature-detect at startup.
- Upload it outside the auto-discovery roots (e.g. `~/.omp/app/`) so the user's TUI doesn't load it.
- [INFERENCE] Whether `/omp-app` prompts land in prompt history: not checked.

## 5. Upstream RPC additions that would close the gaps
- Already on main (18.3.1): `open_session`, `set_event_filter`, `prompt_result` status, `session_settled`, `--no-ui`, settings `fs.watch`.
- Proposed in #13281:
  - stop the TUI-only fall-through and advertise `tuiOnly`;
  - plain or structured `command_output`;
  - route pickers through dialog frames;
  - `get_settings_schema` / `get_settings` / `set_setting`, `get_extensions` / `set_extension_enabled`, `get_agents` / `set_agent_model`.
- Still missing:
  - `list_sessions`, `delete_session`, `fork`, `navigate_tree`, `reset_context`;
  - mode commands for plan/goal/vibe/loop plus plan-review frames;
  - secret-input negotiation or `set_credential`;
  - `get_theme`;
  - a typed approval frame and a public extension-UI listener on `RpcClient` (#5742 comment).

## 6. Daemon delivery options (secondary)
| Opt | Feasibility / evidence | Runtime deps | Size | Version skew | Install / upgrade over SSH | Blockers | SDK reach |
|---|---|---|---|---|---|---|---|
| A: npm + Bun | SDK exports TS source (`exports ./src/*.ts`, `engines bun>=1.3.14`; imports `bun:sqlite`), so Bun only | Bun ≥1.3.14 plus `@oh-my-pi/pi-natives-<tag>` | ~160 MB natives plus deps [INFERENCE] | pin to `omp --version`; separate natives cache per version | `bun add @oh-my-pi/pi-coding-agent@X` | Bun on the remote. Variant: `BUN_BE_BUN=1 omp run d.js` uses omp's own Bun (Bun docs) [untested] | full SDK |
| B: compiled binary | same pipeline as omp (`compile-binary.ts`: bytecode +52 MB, embedded natives via `gen:native`) | none | ≈200 MB per target (omp = 198.8 MB); 8 targets incl. musl and win-arm64 | SDK frozen at build; natives loader deletes older version dirs, causing churn against the installed omp | app uploads binary + checksum (the T3 Code pattern: `~/.t3/runtime`) | shipping 8 targets × versions; Darwin codesign | full SDK |
| C: extension inside installed omp | host modules are shared (§4); `Bun.serve` works in-process (auth-broker precedent); multi-session via `createAgentSession` + private `AgentRegistry` (omp://sdk.md) | installed omp | tiny | locked to the installed omp automatically, but internal-API churn | upload `.js`, run `omp --mode rpc --no-session -e d.js` with stdin held open (exits on EOF, omp://rpc.md) | detachment (nohup/tmux/broker); `hub` cross-session bug #10229 | full SDK |
| D: no daemon | §2–§4; precedents: robomp (`omp --mode rpc` per issue) and 18.0.8 "custom RPC launcher builders … through SSH" (CHANGELOG) | installed omp | 0 | none (same binary) | install omp only | stdin EOF disposes the session and aborts the turn (omp://rpc.md, omp://sdk.md) | RPC + CLI + SFTP (+ companion ≈ full) |
| E: upstream `omp serve` | absent (omp://cli-reference.md subcommand table; no `serve` command file); #5742 open since 2026-07-16 | – | – | – | – | no maintainer decision | – |

## 7. Version-compat facts
- **Session format:** v3; migrations v1→v2→v3 run on load and the file is rewritten on the next persist (omp://session.md). Older omp reading newer files: not verified.
- **Natives:** stored at `~/.omp/natives/<ver>` (observed: 18.3.0, 160.0 MB). The loader checks a version sentinel and deletes older semver dirs after loading (omp://natives-addon-loader-runtime.md).
- **Daemon broker scopes (observed):** `~/.omp/run/daemons/<hash>/{broker.pid, broker.token, scope.json, clients/}` and `global/<svc>/`. The socket is `broker.sock` (`launch/paths.ts`).

## 8. Remote install
- **POSIX:** `curl -fsSL https://omp.sh/install | sh -s -- --binary --ref vX` with `PI_INSTALL_DIR` (default `~/.local/bin`). Without `--binary`, the script prefers `bun install -g` when Bun is present. It smoke-tests with `omp --version`; musl needs `libstdc++` / `libgcc`.
- **Windows:** `install.ps1 -Binary -Ref vX`, installing to `%LOCALAPPDATA%\omp`. `-Ref` alone implies `-Source`.
- **Offline or pinned:** fetch `https://github.com/can1357/oh-my-pi/releases/download/vX/omp-<darwin|linux|linux-musl>-<x64|arm64>` or `omp-windows-<x64|arm64>.exe` plus `SHA256SUMS.txt`, then SFTP-upload.
- **Existing installs:** brew (`can1357/tap/omp`), mise (`github:can1357/oh-my-pi`), nix, bun, npm. `omp update` detects which (`update-cli.ts:582`).

## 9. Unverified
- `omp ps --help` output (only its flags from source).
- RSS of an idle rpc process (cold start measured: 1.7 s to `ready` plus four introspection commands, local macOS).
- Plan/goal mode APIs for extensions.
- Rendering pi-tui components to ANSI lines from the companion.
- `BUN_BE_BUN` behaviour on the omp binary.
