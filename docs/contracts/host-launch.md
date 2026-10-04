# host-launch: the environment omp runs with

What environment omp gets when the app starts it, per host kind: the login-shell PATH the probe learns, the
variables that turn on a run's idle exit, and the file that keeps a Mac awake while omp works. Code:
`packages/omp_core/lib/src/host/probe.dart` (the probe), `lib/src/channel/detached_run.dart`,
`lib/src/channel/windows_run.dart`, `lib/src/channel/attached_channel.dart` and `lib/config/omp_cli.dart` (the
launches), `lib/src/host/keep_awake.dart` and `companion/src/keep-awake.ts` (keep awake).

## Why this contract exists

An SSH exec channel runs a non-login, non-interactive shell, so a process started from it inherits sshd's
default PATH — `/usr/bin:/bin:/usr/sbin:/sbin` on macOS, `/usr/local/sbin:…:/usr/bin:…` from
`/etc/environment` on Debian/Ubuntu. Everything a user's profile files add is missing: Homebrew's
`brew shellenv` (`.zprofile` on macOS), `~/.local/bin`, nvm, `~/.bun/bin`. omp's bash tool runs its commands
with omp's own environment, so a `gh` in `/opt/homebrew/bin` is `command not found` (exit 127) inside a
session even though the same omp finds it in a terminal.

The same holds for "this computer" on macOS: an app started from Finder or the Dock gets launchd's minimal
PATH, not the one the user's terminal has.

Measured (2026-09-26, macOS 25.6 and the `harness/sshd` Ubuntu container): exec-channel PATH
`/usr/bin:/bin:/usr/sbin:/sbin` and `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin`;
`bash -lc 'echo $PATH'` on the container adds `/home/omp/.local/bin`, `zsh -lic 'echo $PATH'` on the Mac adds
Homebrew and every directory `~/.zshrc` prepends.

## The probe reads the login PATH (`HostProbe.loginPath`)

- Part of the POSIX probe script, so one connection probe costs one extra login shell, not one extra round
  trip: about 0.1 s (measured on the `harness/sshd` container, and on a Mac with Homebrew and a `.zshrc`).
  Windows probes do not do this (see below), and neither does the POSIX probe on a Windows POSIX shell
  (MSYS, Cygwin), which the Windows probe replaces.
- **Shell**: `$SHELL` when it is executable, else the account's login shell from the passwd entry
  (`getent passwd`, or `dscl . -read /Users/<user> UserShell` on macOS). zsh is never assumed.
- **Home**: the account's home from the same passwd entry (`NFSHomeDirectory` on macOS), falling back to
  `$HOME`, so an isolated `HOME` (`OMPANION_LOCAL_HOME` in development builds) or sshd's `SetEnv HOME` does
  not change the answer — the probe reports the PATH a terminal on that machine gives the user.
- **Flags**: `-l -i -c` — an interactive login shell, which is what a terminal runs: `.zprofile` and
  `.zshrc` for zsh, `.bash_profile` and `.bashrc` for bash, `config.fish` for fish, `config.nu` for nushell.
  `-i` is what reaches PATH entries that live in `.zshrc`/`.bashrc` (measured on the Mac that reported the
  bug: `-l -c` alone misses `~/.local/bin`, `~/.bun/bin`, Flutter and Android). A second attempt with
  `-l -c` runs only when the first answered nothing: a shell that rejects `-i`, or an interactive rc that
  hangs or `exec`s another program (tmux, another shell). That answer lacks what only the interactive rc
  adds. csh and tcsh accept `-l` only as their sole flag, so both attempts fail there.
- **What is read**: the shell prints a newline and a random marker, `printenv PATH`, then the marker again;
  the one line between the markers is the answer. `printenv` rather than `"$PATH"` because fish joins its PATH
  list into the exported, colon-separated variable and nushell converts its list back for an external
  command (measured: fish 4.9.3, nushell 0.116, bash, dash, zsh). No other variable leaves the shell: an rc
  may export secrets.
- **Noise**: the shell's output goes to a `mktemp` file (0600, random name, removed afterwards) in `$TMPDIR`,
  else `/tmp`, so rc banners, `echo`s, prompts and `.zcompdump` noise cannot corrupt the answer, a file
  planted in a shared `/tmp` is never written, and a shell that runs something unexpected on startup cannot
  reach the app's own protocol. The leading newline keeps the marker on its own line after rc output
  that does not end in one (`printf "loading..."`).
- **Bound**: 5 s per attempt (`posixProbeScript`'s `loginWait`, in tenths of a second, is a parameter so
  tests do not wait it out); a shell still running then gets SIGTERM and, 1 s later, SIGKILL (interactive
  bash and zsh ignore SIGTERM). Measured on the container: an rc that `exec`s a hanging program costs 5.5 s,
  a hanging command in `.bashrc` 6.5 s, one in `.profile` (both attempts hang) 11.9 s, on every connection.
- **Failure**: `loginPath` is null and `loginProblem` says which way (`no login shell`, `the login shell
  reported no PATH`, `cannot create a temporary file in <dir>`). The launch then keeps the exec PATH, and the
  machine details pane shows a warning fact (`Login PATH`).
- **Side effects**: the rc files run on every connection, and whatever they start outlives the probe: a
  daemon (`eval $(ssh-agent)` in `.bashrc` starts one more agent per connection) and a command still running
  in the rc when the shell is killed. An interactive zsh may rewrite its `compinit` cache
  (`~/.zcompdump-*`); no shell history is written for `-c` (measured).

## Where the PATH is applied

- **Detached POSIX run** (`run.sh`): the login PATH travels as `$1` of the inner `sh -c` that records
  `omp.pid` and `exec`s omp, which prepends it to omp's own PATH. Only omp is affected: the pipeline's
  `tail`, `ps`, `mkdir` and `kill`, and the pump that writes omp's output to `out.jsonl` (the omp binary as Bun, with
  `BUN_BE_BUN=1` in front of it alone), keep the PATH sshd gave the wrapper, so a user PATH that shadows a system
  tool cannot break liveness, the log or the exit record.
- **Attached POSIX run** (the control process): the statement from `HostProbe.loginPathExport` before omp's
  command line.
- **One-shot `omp` CLI calls** (`runOmp`): the same statement.
- **`omp update`** (`updateOmp`, `packages/omp_core/lib/src/host/install.dart`): the same statement, then the
  directory of the omp the app drives in front of it. omp's updater replaces the `omp` its PATH resolves to, which
  must be that one, not another omp earlier on the login PATH; the login PATH stays for what the updater runs
  (`brew`, `mise`, `bun`, `npm`, `gh` for a GitHub token). On Windows only that directory goes in front.
- The login PATH is **prepended**, never substituted: `PATH=<login PATH>:"$PATH"`. omp and the scripts keep
  finding the system directories even when the user's PATH is odd.
- **Windows**: nothing changes. An exec session's PATH comes from the registry (machine PATH plus user
  PATH), which is what a console on that machine sees too; there is no profile-file PATH a session misses.
- **The terminal tab** already starts the user's login shell (`remoteShellLaunch`,
  `lib/terminal/shell_launch.dart`: `exec "${SHELL:-/bin/sh}" -l`), so it needs no login PATH probe.

## Idle exit (`OMPANION_RUN`, `OMPANION_IDLE_EXIT_MS`)

Every detached run's omp gets its run directory and the idle time the app chose (`MachineRuntime.idleExit`, 1 hour,
in milliseconds). The companion then ends that omp once the run sat idle that long (`ompx.md`, `run.idleExit`).

- **Detached POSIX run** (`run.sh`): `OMPANION_RUN="$d" OMPANION_IDLE_EXIT_MS=<ms>` in front of the inner `sh -c`
  that `exec`s omp, so omp gets them and the feeding `tail` does not.
- **Windows**: the WMI environment block carries `OMPANION_RUN` for `run.cmd` and `feed.ps1` anyway;
  `OMPANION_IDLE_EXIT_MS` joins it. `OMPANION_*` variables inherited from the SSH session are dropped first.
- **The control process and one-shot CLI calls** get neither: they end with their exec channel.
- **Inheritance**: everything omp starts inherits both, including an app run from a session's bash tool and the
  control process it starts. The companion acts only when omp's own command line holds `<OMPANION_RUN>/overlay.yml`
  (`\` on Windows), the overlay path the launch passes with `--config`, so no other omp takes itself for the run's.
- **Malformed**: an `OMPANION_IDLE_EXIT_MS` that is not a positive integer throws in the companion's start, which
  omp reports as an `extension_error`.

## Keep awake (`~/.ompanion/keep-awake`)

A Mac in a dark wake ignores omp's own sleep prevention: `power.sleepPrevention` defaults to `idle`
(`caffeinate -i`), a `PreventUserIdleSystemSleep` assertion, which "has no effect if the system is in Dark Wake"
(`IOPMLib.h`). A sleeping Mac that a device's request wakes goes back to sleep 10 to 60 s later, in the middle of the
model request. The stream dies, and omp's stall watchdog reports it at the next wake: the next request from a device,
or the Mac's own maintenance wake about every 15 minutes. Measured 2026-10-03 with `pmset -g log` on a MacBook on AC
power with `sleep 1`: a phone started a session at 16:04 on a Mac asleep since 15:21, which did not fully wake until
23:48. Each of the session's 28 failed attempts started within 1.2 s of a dark wake.

- **Switch**: the empty file `~/.ompanion/keep-awake` (0600), one per machine and the same for every device. The
  machine page's Power card creates and removes it (`setKeepAwake`). The card shows only for macOS machines.
- **Companion** (macOS only, in every omp that loads it): when omp starts work (`agent_start`, `turn_start`,
  `auto_compaction_start`, `auto_retry_start`) and the file exists, it takes `PowerAssertion.start({idle, system})`
  from `@oh-my-pi/pi-natives`. These are `PreventUserIdleSystemSleep` and `PreventSystemSleep` (`caffeinate -i -s`),
  named `ompanion: omp is working`. Every 5 s it checks two things: whether omp still works (streaming or a prompt in
  flight, a retry, a compaction, a handoff, user bash or Python), and whether the file still exists. When either
  stops, it releases the assertion. While nothing is held, the companion reads the file only when work starts.
- **Power**: `PreventSystemSleep` keeps a dark wake going on AC power only. On battery only the idle assertion is
  left, which a dark wake ignores. Neither assertion wakes the display or keeps it on.
- **Runs**: a run uses the companion it was launched with. Runs launched before an app with this feature keep omp's
  behaviour until they exit.
- **Untested**: a Mac with its lid closed.

## Not carried over

Only `PATH` is taken from the login shell, not the rest of its environment (nvm/conda variables,
`JAVA_HOME`, tool-specific variables a user's rc exports). omp's bash tool runs with omp's environment plus
that PATH. A shell that rejects both flag sets (csh, tcsh) keeps the exec PATH, with the reason in the
machine details.
