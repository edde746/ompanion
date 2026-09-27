# host-launch: the PATH omp runs with

What environment omp gets when the app starts it, per host kind, and how the probe learns the machine's
login-shell PATH. Code: `packages/omp_core/lib/src/host/probe.dart` (the probe),
`lib/src/channel/detached_run.dart`, `lib/src/channel/attached_channel.dart` and `lib/config/omp_cli.dart`
(the launches).

## Why this contract exists

An SSH exec channel runs a non-login, non-interactive shell, so a process started from it inherits sshd's
default PATH — `/usr/bin:/bin:/usr/sbin:/sbin` on macOS, `/usr/local/sbin:…:/usr/bin:…` from
`/etc/environment` on Debian/Ubuntu. Everything a user's profile files add is missing: Homebrew's
`brew shellenv` (`.zprofile` on macOS), `~/.local/bin`, nvm, `~/.bun/bin`. omp's bash tool runs its commands
with omp's own environment, so a `gh` in `/opt/homebrew/bin` is `command not found` (exit 127) inside a
session even though the same omp finds it in a terminal.

The same holds for "this computer" on macOS: an app started from Finder or the Dock gets launchd's minimal
PATH, not the one the user's terminal has.

Measured (2026-09-26, macOS 25.6 and the `testing/sshd` Ubuntu container): exec-channel PATH
`/usr/bin:/bin:/usr/sbin:/sbin` and `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin`;
`bash -lc 'echo $PATH'` on the container adds `/home/omp/.local/bin`, `zsh -lic 'echo $PATH'` on the Mac adds
Homebrew and every directory `~/.zshrc` prepends.

## The probe reads the login PATH (`HostProbe.loginPath`)

- Part of the POSIX probe script, so one connection probe costs one extra login shell, not one extra round
  trip: about 0.1 s (measured on the `testing/sshd` container, and on a Mac with Homebrew and a `.zshrc`).
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
  `tail`, `ps`, `mkdir` and `kill` keep the PATH sshd gave the wrapper, so a user PATH that shadows a system
  tool cannot break liveness or the exit record.
- **Attached POSIX run** (the control process): the statement from `HostProbe.loginPathExport` before omp's
  command line.
- **One-shot `omp` CLI calls** (`runOmp`): the same statement.
- The login PATH is **prepended**, never substituted: `PATH=<login PATH>:"$PATH"`. omp and the scripts keep
  finding the system directories even when the user's PATH is odd.
- **Windows**: nothing changes. An exec session's PATH comes from the registry (machine PATH plus user
  PATH), which is what a console on that machine sees too; there is no profile-file PATH a session misses.
- **The terminal tab** already starts the user's login shell (`remoteShellLaunch`,
  `lib/terminal/shell_launch.dart`: `exec "${SHELL:-/bin/sh}" -l`), so it needs no login PATH probe.

## Not carried over

Only `PATH` is taken from the login shell, not the rest of its environment (nvm/conda variables,
`JAVA_HOME`, tool-specific variables a user's rc exports). omp's bash tool runs with omp's environment plus
that PATH. A shell that rejects both flag sets (csh, tcsh) keeps the exec PATH, with the reason in the
machine details.
