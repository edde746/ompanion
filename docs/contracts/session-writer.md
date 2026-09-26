# session-writer: who else is writing a session file

How the app tells that a session file belongs to another omp process, what it shows then, and when it may take the
session over. Code: `packages/omp_core/lib/src/host/session_writer.dart` (the probe),
`packages/omp_core/lib/src/store/external_writer.dart` (the rules),
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

1. **Write descriptors.** A process holding the session file open for writing. `lsof -w -- <file>` when `lsof`
   exists (macOS always; Linux when installed), parsed from its plain table because `-F` prints no access mode:
   the FD column's trailing `w`/`u`. Without `lsof`, a `/proc/<pid>/fd` walk: `readlink` each descriptor against
   the path, then `fdinfo/<fd>`'s `flags` — the low two bits are the access mode (0 read, 1 write, 2 read-write).
   omp holds this descriptor from the session's first append for the life of the process
   (`FileSessionStorageWriter`: "Open file once, keep fd for lifetime";
   `SESSION_WRITE_FLAGS = O_WRONLY | O_CREAT` plus `O_APPEND`), so it is present while a turn runs and while an
   idle omp sits at its prompt.
2. **Terminal breadcrumb.** omp writes `<agentDir>/terminal-sessions/<terminal id>` with the session file on its
   second line (`session-paths.ts`, `writeTerminalBreadcrumb`). The app reads every profile's directory
   (`<agentDir>`, and the one the file's own path names) and keeps a crumb whose line 2 is this file **and** whose
   terminal still runs an omp: the id names a tty (`ttys004` on macOS, `pts-3` → `pts/3` on Linux), `ps -eo
   pid=,tty=,command=` finds a process on that tty whose command looks like an omp
   (`(^|[/ \t])omp(\.(js|ts))?([ \t]|$)`), and its PID is reported. This is the backstop for a writer that holds
   no descriptor yet — an omp that opened a session but has not appended its first entry.

A breadcrumb is **not** liveness by itself: omp never removes one (only `omp gc` reads them), so a crumb of a
closed terminal must not lock the app out of a session it could own. Only a crumb with a live omp on its tty
counts, and a crumb naming no tty (a multiplexer or emulator id) is ignored rather than guessed at.

## Ownership (pure function)

`sessionOwnership({appRun, writer})`:

| app run holds it | writer | result | what the app does |
|---|---|---|---|
| yes | anything | `appRun` | attach to that run, unless its omp is behind the file (below) |
| no | null | `free` | launch its own run (`--session <file>`) |
| no | non-null | `foreign` | read the file, launch nothing |

`appRun` is the app's own run lookup (`~/.ompanion/run/*/meta.json`, `listRuns`); it is checked before the probe,
and the launch itself re-checks under the machine's launch lock, so two devices race into the same run and never
into a second writer.

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

`polledWriter({probed, changed, quietFor})` folds one poll into the writer state:

- `busy` — a write within `externalWriteWindow` (10 s): the file grew or its mtime moved since the previous poll.
  A held descriptor alone is **not** busy: an idle omp at its prompt holds it too. Measured: 24 s of no change
  with the descriptor still held and the writer still alive.
- `idleFor` — how long the file has been unchanged; a write resets it to zero.

The app polls every 2 s while a reader is open (the file for the transcript, the machine for the writer).

## Reading (`ExternalSession`)

`ExternalSession implements LiveSession` reads the file and nothing else:

- the head (title slot, session header) for the name, the appended entries for the transcript
  (`sessionFileEntries` + the same `withEntries` reducer as a run, so rows match a live session's);
- only the bytes appended since the last poll, parsed on another isolate when the chunk is over 64 KiB; a file
  that shrank or was rewritten in place (omp replaces the title slot at the head without changing the size) is
  read whole;
- `SessionView.external` carries the writer, so the composer, the header and the sidebar read it from the view;
- `rpc`, `companion` and `stop()` throw `UnsupportedError`: there is no process to command, and a prompt invented
  here would reach a model as a stranger's turn.

What it cannot show, and says so instead of faking it: the model, the thinking level, open dialogs, the todo list,
and the other process's queued steering and follow-up messages (they live in that process's memory only —
`#pendingNextTurnMessages`; nothing is persisted).

## Take-over

The app may stop reading and start its own run for the file only when the probe finds **nobody**: no write
descriptor, no live terminal on the crumb. Then the composer's Take over calls
`SessionsProvider.takeOver`, which re-probes, launches (`ResumeSession`) and swaps the reader for the run; while
a writer is still there it returns the reader and the button stays disabled with the reason.

An **idle but alive** writer is still a writer: that process holds the session's history and leaf in memory, so
launching there would recreate the two-writer bug as soon as the user types in either UI. Take-over therefore
waits for the process to exit, not for it to fall quiet.

## Limitations

- **POSIX only.** `probeSessionWriter` returns null on Windows: there is no `/proc` and no `lsof`, and an omp
  breadcrumb there names a Windows Terminal session (`wt-…`), not a device the process table shows. A Windows host
  therefore keeps the old behaviour — the app may start a second omp for a session another process holds.
- A crumb whose terminal id is a multiplexer or emulator id (`tmux-%7`, `kitty-3`, `apple-…`) names no tty the app
  can check, and is ignored. In practice an interactive omp in a pty (`ttyname(3)`) gets a tty-shaped id, so this
  only affects a non-interactive launch.
- The probe is a guard, not a lock: a process that opens the file between the probe and the launch is not seen.
  The app's own launches are serialised by the machine's launch lock and `meta.json` scan; a foreign process does
  not cooperate either way.
