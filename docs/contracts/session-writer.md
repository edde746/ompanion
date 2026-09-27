# session-writer: who else is writing a session file

How the app tells that a session file belongs to another omp process, what it shows then, and when it may take the
session over. Code: `packages/omp_core/lib/src/host/session_writer.dart` (the probe),
`packages/omp_core/lib/src/store/external_writer.dart` (the writer and whether it is in a turn),
`packages/omp_core/lib/src/session/external_session.dart` (the reader),
`packages/omp_core/lib/src/session/machine_runtime.dart` (`open` refuses to launch for a held file).

## Why this contract exists

Two omp processes appending to one session file interleave their turns in one JSONL, and each process's later
rewrite (compaction, `/clear`, a session switch) drops the other's entries. Measured on macOS (2026-09-26) with
the app's own open path against a terminal omp mid-turn: the app launched a second omp on the same file, both
held it open for writing (`lsof`: two PIDs, `30w` each), the app's user message and assistant reply landed
between the terminal's tool call and its tool result, and the app's omp appended
`{"type":"custom","customType":"session_exit","reason":"sighup"}` inside a session the terminal still owned — a
record on which omp's next resume hangs a synthetic aborted turn.

The app must never be that second writer. It reads such a file and says what is true about it.

## The probe (`probeSessionWriter`)

One POSIX shell round trip per session, returning `ExternalWriter?` (null: nobody). It answers two independent
questions and either one names a writer:

1. **Write descriptors.** A process holding the session file open for writing. Where `/proc/self/fd` exists
   (Linux), a walk of `/proc/<pid>/fd` in shell builtins: `[ fd -ef file ]` compares device and inode, then
   `fdinfo/<fd>`'s octal `flags` give the access mode in the low two bits (0 read, 1 write, 2 read-write). Measured
   on the Docker test machine with 10,221 descriptors: 80 ms; a `readlink` per descriptor took 3 s. Elsewhere (macOS)
   `lsof -w -- <file>`, parsed from its plain table because `-F` prints no access mode: the FD column's `w`/`u`
   after the descriptor number (50–170 ms on a Mac with 337 processes). BusyBox's `lsof` is never used: it ignores
   its arguments and prints no mode. A reader (`tail -f`, an editor's view) is not a writer.
   omp opens this descriptor (`O_WRONLY | O_CREAT | O_APPEND`) at its first append after it opened or rewrote the
   file, and closes it when it rewrites the file, switches sessions or exits (`session-storage.ts`,
   `session-manager.ts`, omp 18.3.1). An idle omp at its prompt after a turn holds it; an omp that resumed the file
   and has not appended does not.
2. **Terminal breadcrumb.** omp writes `<agentDir>/terminal-sessions/<terminal id>` with the session file on its
   second line whenever it opens a session (`session-paths.ts`, `writeTerminalBreadcrumb`). The app reads every
   profile's directory (`<agentDir>`, and the one the file's own path names) and keeps a crumb whose line 2 is this
   file **and** whose terminal still runs an omp: the id names a tty (`ttys004` on macOS, `pts-3` → `pts/3` on
   Linux; `ttyname(0)` with `/dev/` dropped and `/` replaced), `ps -eo pid=,tty=,args=` finds a process on that
   tty whose command looks like an omp (`(^|[/ \t])omp(\.(js|ts))?([ \t]|$)`), and its PID is reported. This is
   what catches an omp that holds no descriptor yet.

A breadcrumb is **not** liveness by itself: omp never removes one (only `omp gc` reads them), so a crumb of a
closed terminal must not lock the app out of a session it could own. Only a crumb with a live omp on its tty
counts, and a crumb naming no tty (a multiplexer or emulator id) is ignored rather than guessed at.

## Ownership

| app run holds it | writer | what the app does |
|---|---|---|
| yes | anything | attach to that run, unless its omp is behind the file (below) |
| no | null | launch its own run (`--session <file>`) |
| no | non-null | read the file, launch nothing |

The app's own runs (`~/.ompanion/run/*/meta.json`, `listRuns`) are looked up before the probe, so an app omp
holding the file, from this device or another, is attached to and never counted as foreign. The launch itself
re-checks under the machine's launch lock, so two devices race into the same run and never into a second writer.

## A run of the app that another process wrote past

A run of the app holds its session in memory from the moment omp loaded the file. A terminal omp that resumes the
same file later appends turns this run never sees, and the run's omp holds no write descriptor while it is idle
(omp opens it on its first append), so nothing stops the terminal. Attaching to that run shows the old history, and a
prompt there continues from the old leaf.

`open(ResumeSession)` therefore checks the run it attaches to: the attach reads the file's last entry and asks omp
for `get_entries` since it; `unknown_since` while `get_state` still names this file sets `RunSession.behindFile`.
Such a run is detached and killed (`killRun`: SIGKILL on POSIX, a terminate on Windows), then the file is opened as
if no run held it: read (`ExternalSession`) when a writer is there, else a fresh run. Killed, not stopped: omp's
exit, graceful or on SIGTERM, appends `session_exit` under its own old leaf, which makes that leaf the file's last
entry, and the reader then shows the conversation without the other process's turns (measured with omp 18.3.1,
2026-09-27).

An app run that is already attached on this device when another process starts writing is not checked; it shows the
old history until it is attached again.

## Busy vs idle

`ExternalWriter.busy` comes from the file, not from the clock (`turnInFlight`): the last message entry leaves a turn
open when it is a user message or a tool result (the model is answering) or an assistant message that stopped for
tool use (its tools run). omp appends a message when it ends, so a long reply or a long tool run leaves the file
unchanged for minutes while the turn goes on, and a finished turn is idle the moment its last message lands. A held
descriptor alone says nothing: an idle omp at its prompt holds it too.

The app looks every 2 s while a reader is open: one `stat` of the file and one probe. A turn that ended without
its last message (the process was killed) reads as open until the writer is gone.

## Reading (`ExternalSession`)

`ExternalSession implements LiveSession` reads the file and nothing else:

- the head (title slot, session header) for the name, read again on every change because omp rewrites the title
  slot in place; the entries for the transcript (`sessionFileEntries` + the same `withEntries` reducer as a run,
  so rows match a live session's);
- like a run, a file over 16 MiB opens with its last 2 MiB and `loadEarlier` reads the pages before;
- after that, only the bytes after the last complete line read, when the 64 bytes before it are unchanged. A line
  omp is still writing waits for its newline. A file that shrank or whose earlier bytes changed (omp replaces the
  whole file through a temporary file for some changes, e.g. a workspace directory added, a repair) is read afresh;
- chunks over 64 KiB are parsed on another isolate;
- `SessionView.external` carries the writer, so the composer, the header and the sidebar read it from the view;
- `rpc`, `companion` and `stop()` throw `UnsupportedError`: there is no process to command, and a prompt invented
  here would reach a model as a stranger's turn. The chat hides branch and reset for it, and the session menu's
  Stop is disabled;
- three failed looks in a row close it (`LinkClosed`); opening it again probes afresh.

What it cannot show, and says so instead of faking it: the model, the thinking level, open dialogs, the todo list,
and the other process's queued steering and follow-up messages (they live in that process's memory only —
`#pendingNextTurnMessages`; nothing is persisted).

## Take-over

The app may stop reading and start its own run for the file only when the probe finds **nobody**: no write
descriptor, no live terminal on the crumb. Then the composer's Take over calls `SessionsProvider.reopen`, which
opens the file again (`ResumeSession`): the runtime probes, and hands back the same reader while a writer is there
(the button says why), else launches and swaps the reader for the run.

An **idle but alive** writer is still a writer: that process holds the session's history and leaf in memory, so
launching there would recreate the two-writer bug as soon as the user types in either UI. Take-over therefore
waits for the process to exit, not for it to fall quiet.

## Limitations

- **POSIX only.** `probeSessionWriter` returns null on Windows: there is no `/proc` and no `lsof`, and an omp
  breadcrumb there names a Windows Terminal session (`wt-…`), not a device the process table shows. A Windows host
  therefore keeps the old behaviour — the app may start a second omp for a session another process holds.
- A crumb whose terminal id is a multiplexer or emulator id (`tmux-%7`, `kitty-3`, `apple-…`) names no tty the app
  can check, and is ignored. omp takes a tty-shaped id whenever its stdin is a terminal, so this affects only an omp
  without one (`omp -p`, another client's RPC process): such a process is seen once it appended to the file, not
  before.
- Processes of another account are not seen: `/proc/<pid>/fd` and `lsof` show only the probing account's own.
- The probe is a guard, not a lock: a process that opens the file between the probe and the launch is not seen.
  The app's own launches are serialised by the machine's launch lock and `meta.json` scan; a foreign process does
  not cooperate either way.
