# Windows hosts, omp v18.3.1 over Win32-OpenSSH

Evidence: omp source at tag v18.3.1, Microsoft Learn, PowerShell/Win32-OpenSSH issues. Unverified claims are marked [INFERENCE].

## 1. Server facts

| Topic | Finding | Evidence |
|---|---|---|
| Default shell | cmd.exe. Configurable via `HKLM\SOFTWARE\OpenSSH\DefaultShell`. Optional `DefaultShellCommandOption` (default `-c`; cmd, PowerShell and bash are handled specially) and `DefaultShellEscapeArguments`. | https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration ; https://github.com/PowerShell/Win32-OpenSSH/wiki/DefaultShell |
| Unsupported sshd options | `AcceptEnv`, `PermitUserEnvironment`, `AllowStreamLocalForwarding`, … So environment variables can't be passed over SSH, and there is no Unix-socket forwarding. | MS Learn (same page) |
| SFTP | On by default: `Subsystem sftp sftp-server.exe`. Paths look like `/C:/Users/John`. Admin keys live in `__PROGRAMDATA__/ssh/administrators_authorized_keys`. | https://raw.githubusercontent.com/PowerShell/openssh-portable/latestw_all/contrib/win32/openssh/sshd_config ; https://github.com/PowerShell/Win32-OpenSSH/issues/48 |
| PTY | ConPTY on Windows 10 / Server 2019 and later; `ssh-shellhost.exe` on older systems. Use **no-PTY exec** for RPC. PTY sessions kill children on disconnect, and ConPTY output is VT-rendered [INFERENCE: this would corrupt JSON]. | https://github.com/PowerShell/Win32-OpenSSH/wiki/TTY-PTY-support-in-Windows-OpenSSH ; issue #1751 |
| Job object | sshd starts the channel's first process inside a job with `KILL_ON_JOB_CLOSE`, and that process holds the only job handle. When it exits, every other process still in the job is killed. Breakaway is allowed. A breakaway child that inherited the SSH pipe handles makes sshd hang. | https://github.com/powershell/win32-openssh/issues/2452 ; #1032 (breakaway allowed since v7.6.0.0p1); #1751 (maintainer: `JOB_OBJECT_LIMIT_BREAKAWAY_OK` added) |
| Disconnect behaviour | The job is not reliably killed on disconnect. Non-PTY exec children kept running after the client was killed (#1751, open, still reported in Oct 2025). `ssh -t` does kill them. Children started with Start-Process/`start` still die when the first process exits (#1032 comment, #2452). | https://github.com/PowerShell/Win32-OpenSSH/issues/1751 ; discussion #2240 |
| Job inheritance | Children created with `CreateProcess` inherit the job. **Children created via `Win32_Process.Create` are not associated with it.** `KILL_ON_JOB_CLOSE` terminates members when the last handle closes. | https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects (lines 73, 75, 121) |
| Signals | Windows has no signals. SIGTERM is never generated. `kill` means unconditional termination. SIGHUP fires on console close; SIGBREAK on Ctrl+Break. omp registers handlers only for SIGINT/SIGTERM/SIGHUP, so `taskkill /F` and `Stop-Process` skip its cleanup. The graceful path is **closing stdin**. | https://nodejs.org/api/process.html (signal events); postmortem.ts:503-505,580-587; rpc-mode.ts:1745-1758 |

## 2. Running a probe over exec

- **Command form:** `C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand <base64(UTF-16LE)>`.
  - Shell-agnostic: works under a cmd, PowerShell or bash default shell [INFERENCE].
  - The payload never goes through metacharacter parsing. omp itself uses this pattern and anchors to System32 because some PATHs drop it (utils/open.ts:44-69).
- **Size limit:** a cmd.exe line is capped at 8191 characters (https://learn.microsoft.com/en-us/troubleshoot/windows-client/shell-experience/command-line-string-limitation), so the encoded script must stay around ≤3 KB. For anything larger, upload a `.ps1` to `%TEMP%` over SFTP and run it with `-File`.
- **Output hygiene:**
  - Wrap payload lines in markers, as omp does (connection-manager.ts:486-500,562), to skip banner and profile noise.
  - Set `$ProgressPreference='SilentlyContinue'` (avoids CLIXML on stderr) [INFERENCE].
  - Set `[Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)` [INFERENCE].
- **What to probe:**
  - OS architecture, using the `PROCESSOR_ARCHITEW6432` / `PROCESSOR_ARCHITECTURE` logic from install.ps1:31-46.
  - `$PSVersionTable.PSVersion`, and whether pwsh ≥ 7.4 is installed.
  - DefaultShell (`Get-ItemProperty HKLM:\SOFTWARE\OpenSSH`).
  - OpenSSH version.
  - `%LOCALAPPDATA%\omp\omp.exe --version`.
  - USERPROFILE and LOCALAPPDATA.
  - Running `omp.exe` processes via `Get-CimInstance Win32_Process`.
- **Reference:** omp's own polyglot probe classifies Windows from `%OS%|%COMSPEC%` or from unexpanded `$VAR`s (connection-manager.ts:562,593-614).

## 3. Installing omp on Windows (scripts/install.ps1)

- **Flags:** `-Source`, `-Binary`, `-Ref <tag>`. `-Ref` on its own implies `-Source` (install.ps1:11-15,327-330). With no flags it uses bun if present (`bun install -g @oh-my-pi/pi-coding-agent`, Bun ≥ 1.3.14), otherwise the binary (338-351,47). Requires PowerShell ≥ 5.1 (19-25).
- **Binary path:** GitHub release asset `omp-windows-{x64|arm64}.exe` (46) → `$env:PI_INSTALL_DIR` or `%LOCALAPPDATA%\omp\omp.exe` (28,316-322). The same asset naming appears in update-cli.ts:1205-1208.
- **PATH:** the install dir is appended to the **user** PATH, which is not visible in the current session (324-330). The app should call the absolute path.
- **Bash shell:** `Configure-BashShell` writes `shellPath` for Git Bash into `%USERPROFILE%\.omp\agent\settings.json` (144-200). That legacy file is migrated into config.yml (settings.ts:2296-2344).
- **App recipe:** `& ([scriptblock]::Create((irm https://omp.sh/install.ps1))) -Binary -Ref v18.3.1` (update-cli.ts:2090-2093), or download `…/releases/download/v18.3.1/omp-windows-x64.exe` directly.
- **Updates:** `omp update` renames the running exe aside, so it works while sessions are running (update-cli.ts:1411-1426,1891-1895).

## 4. omp paths on Windows

XDG only applies on Linux (dirs.ts:7-11,340-376).

| Item | Path | Evidence |
|---|---|---|
| Config root | `%USERPROFILE%\.omp` (`PI_CONFIG_DIR` can rename it) | dirs.ts:4-5,114-116 |
| Agent dir | `%USERPROFILE%\.omp\agent` (`PI_CODING_AGENT_DIR`, `OMP_PROFILE`) | dirs.ts:335-337,584-586 |
| Config file | `…\agent\config.yml` | dirs.ts:30 |
| Auth DB | `…\agent\agent.db` (plain SQLite; no DPAPI anywhere in the source) | dirs.ts:866-868 |
| Sessions | `…\agent\sessions\<enc>\<ts>_<id>.jsonl`. Under home: `-src-app`. Elsewhere: `D:\work\p` → `--D--work-p--`. | dirs.ts:899-902; session.md:40-43; session-paths.ts:44-99 |
| Natives | `%USERPROFILE%\.omp\natives\<ver>\pi_natives.win32-<arch>[-modern\|-baseline].node`, extracted from the binary. Legacy location: `%LOCALAPPDATA%\omp`. | dirs.ts:821-824; natives-addon-loader-runtime.md:20-23,52-54,94-107 |
| Logs / run | `%USERPROFILE%\.omp\logs`, `…\.omp\run\…`. Tiny workers use a **named pipe** on Windows. | dirs.ts:603-605,990-998; local-models.md:41-45 |
| Startup note | omp spawns PowerShell at startup to detect AVX2 | natives doc:44 |

## 5. Attached mode on Windows

- **Launch:** exec with no PTY. With the cmd default shell: `"%LOCALAPPDATA%\omp\omp.exe" --mode rpc-ui -e "C:\…\companion.ts"`. rpc-ui already sets `PI_NO_PTY=1` (main.ts:1838-1840).
- **PowerShell default shell:** sessions never run attached: they use the cmd-redirect and `feed.ps1` file transport of §6, which works under a cmd, PowerShell or bash default shell (`packages/omp_core/test/windows/windows_session_test.dart` runs one with PowerShell set as `OpenSSH\DefaultShell`). The control process does run attached, as `& "<omp.exe>" …` under a PowerShell default shell (`windowsAttachedCommand`, `packages/omp_core/lib/src/channel/attached_channel.dart`). [INFERENCE: that PowerShell passes its stdout through byte for byte; no test runs the control process on a Windows host.]
- **Environment:** can't be sent over SSH (AcceptEnv is unsupported). Use a `--config` overlay or a `set X=Y&&` prefix.
- **Self-termination:** omp exits on stdin EOF (rpc-mode.ts:1745-1758) or when stdout delivery fails (780-783). Because of #1751, still assume orphans are possible: on reconnect, find `omp.exe` processes via `Get-CimInstance Win32_Process` and match a unique marker in the command line (for example a per-session `-e` or `--config` path).
- **Kill:** `Stop-Process -Id <pid> -Force` or `taskkill /PID <pid> /T /F` (`/T` kills the child tree, `/F` forces; https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/taskkill). Both are TerminateProcess. omp's own Windows tree-kill uses a Toolhelp walk (ptree.ts:198-210,383-384). omp does not detach its launch daemons on Windows (launch/spawn-options.ts:12-16).

## 6. Detached variant

**Why the naive approach fails.** Start-Process, `start` and `&` all call CreateProcess, so the child joins the sshd job and is killed when the channel's first process exits (job-objects doc line 73; #2452; the #1032 report of `START` dying when the BAT file exits).

**Built-in escapes, best first.**
1. **`Invoke-CimMethod Win32_Process Create`** with `Win32_ProcessStartup.CreateFlags = 0x01000000` (CREATE_BREAKAWAY_FROM_JOB).
   - WMI-created children are outside the sshd job (job-objects line 73).
   - The flag also escapes the WMI provider-host quota job (https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/create-method-in-class-win32-process line 106; https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-processstartup lines 133-134).
   - The same snippet is given in #1032 (jborean93). It returns the ProcessId.
   - Caveat: the environment block comes from the parent (win32-processstartup, `EnvironmentVariables`). Set USERPROFILE, LOCALAPPDATA and PATH explicitly [INFERENCE: verify], otherwise omp's home and natives dir could land in the wrong profile.
2. **P/Invoke `CreateProcess` with CREATE_BREAKAWAY_FROM_JOB** (allowed per #1032 and #1751). Pass explicit, non-SSH stdio handles, otherwise sshd hangs (#2452).
3. **Task Scheduler.** The maintainers suggest it (#1032), but it has admin, logon-type and credential caveats (jborean93 in #1032).
4. ✗ Do **not** rely on the #1751 behaviour (non-PTY children surviving a dropped connection). It is a bug the maintainers intend to fix.

**Data path.**
- ✗ Avoid `Get-Content -Wait in.jsonl | omp … >> out.jsonl` in Windows PowerShell 5.1:
  - `$OutputEncoding` defaults to ASCII, so non-ASCII becomes `?` (about_preference_variables 5.1, lines 95 and 850).
  - `>` / `>>` write UTF-16LE, and `Get-Content` reads BOM-less files as ANSI (about_character_encoding 5.1).
  - `-Wait` polls once per second (Get-Content docs, line 749).
  - pwsh ≥ 7.4 does preserve native stdout bytes on redirection and piping, but not after `2>&1` (about_redirection 7.5, lines 112, 237, 265). pwsh often isn't installed.
- ✓ Built (`packages/omp_core/lib/src/channel/windows_run.dart`, exercised by `packages/omp_core/test/windows/` and CI's `windows-host` job):
  - Use WMI to create `cmd.exe /d /s /c "<run>\run.cmd"`, which runs `powershell -NoProfile -File feed.ps1 | omp.cmd | pump.cmd`: `omp.cmd` runs `omp.exe --mode rpc-ui -e companion.js 2>> err.log` and saves its exit code, `pump.cmd` appends omp's stdout to `out.jsonl` through `pump.js` (omp's binary as Bun). cmd pipes and redirection pass bytes through unchanged. The first form, `… | omp.exe … >> out.jsonl`, could not be rotated: cmd's `>>` refuses other writers (a truncation fails with a sharing violation) and keeps its own offset; `pump.js` opens the log for appending, so a truncation succeeds and the next writes start at byte 0 (measured on Windows 11 26200, PLAN.md §5).
  - `feed.ps1` is a byte pump: `[IO.File]::Open(path,'OpenOrCreate','Read','ReadWrite')` → `[Console]::OpenStandardOutput()`, polling about every 50 ms. It exits when an `in.jsonl.stop` sentinel appears. omp then sees stdin EOF, disposes and exits gracefully.
  - Client writes: keep a byte-appender exec channel open. SFTP appends fail while `feed.ps1` reads: Win32-OpenSSH's sftp-server opens for writing with `FILE_SHARE_WRITE` only (`ERROR_SHARING_VIOLATION`, SFTP status 4; measured in CI, see m0-detached-sessions.md).
  - Client reads: `in.jsonl` over SFTP with stat plus offset reads. `out.jsonl` over exec through the follow script (omp as Bun), started so that PowerShell never reads its output: `set BUN_BE_BUN=1&& <omp.exe> …` under cmd, `[Diagnostics.Process]::Start` with inherited handles under a PowerShell default shell. `Get-Content -Wait -Tail 0 -Encoding UTF8`, the first idea for an exec follower, only works once console output is set to UTF-8, and has ~1 s latency.
- **Still to spike:** OpenSSH versions on target machines other than 9.5p2. The sharing modes, the WMI environment and the appends were settled in CI (m0-detached-sessions.md, Windows).

**Verdict.**
- Attached rpc-ui over no-PTY exec: **feasible**. Use cmd-default launch strings, byte-transparency self-test, and marker-based stale cleanup.
- Detached sessions with built-ins only: **feasible** via WMI `Win32_Process.Create` with CREATE_BREAKAWAY_FROM_JOB, stdio sent to files, a byte-pump stdin feeder and an SFTP tail. **Not feasible** with Start-Process/start/background jobs or a plain `Get-Content -Wait` pipe under PowerShell 5.1.
- Environment inheritance and file sharing are settled in CI (`packages/omp_core/test/windows/`); the open question is OpenSSH versions other than 9.5p2.
