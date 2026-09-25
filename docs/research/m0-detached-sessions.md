# M0: detached sessions on POSIX hosts, Windows scripts

The POSIX detached session works on macOS and Linux with omp 18.3.1. omp outlives the process and the SSH
connection that launched it. Devices re-attach from a saved byte offset and get only newer lines. Concurrent
appenders never interleave. Rotation is followed by BSD and GNU `tail`. A graceful stop exits 0 in about
80 ms. The Windows form is implemented but has not run on Windows; its scripts were checked with
PowerShell 7 on macOS.

Measured on 2026-09-25 with the omp 18.3.1 release binaries, isolated homes (`testing/omp-home.sh`) and no
model turn.

| Host | Shell (`/bin/sh`) | `tail` | Reached through |
|---|---|---|---|
| this Mac, macOS 26.6.2 | bash 3.2.57 in POSIX mode | BSD | `LocalLink` |
| Ubuntu 24.04.4 container (aarch64, colima) | dash | GNU coreutils 9.4 | `SshLink` (dartssh2 4.1.0) to OpenSSH 9.6p1 |
| Alpine container (probe, listing, `tail`) | BusyBox 1.37.0 | BusyBox | `docker run -i … sh -s` |

Code: `packages/omp_core/lib/src/channel/`. Tests: `test/channel/detached_omp_test.dart`
(`dart test -P integration -t omp`) and `test/channel/detached_docker_test.dart` (`-t docker`, after
`testing/sshd/up.sh`).

## Results

| Question | macOS, local | Linux, over SSH |
|---|---|---|
| omp outlives its launcher | Yes. The launching `sh -s` exits, `run.sh` is re-parented to launchd (pid 1), omp answers `get_state` afterwards. | Yes. The launching SSH connection is closed; `run.sh` is re-parented to pid 1; a second connection lists the run as running, re-attaches and gets answers. |
| Re-attach from a saved offset | Only lines after the offset arrive, byte-identical to `out.jsonl`. | Same; no `ready` is replayed. |
| Opening the same session again | Finds the live run (`launched: false`) under the launch lock. | Same. |
| Two devices appending at once | 2 × 25 `get_state`, all answered, `in.jsonl` has 51 intact lines. | 2 × 20 over two SSH connections, all answered. |
| Peer commands | The second device's inbox marks its own 26 lines as own and the other 25 as not. | Same with 20 + 20. |
| Rotation while attached | Channels continue in generation 2 with offsets from the new file. | Same with GNU `tail`, two channels on two connections. |
| Graceful stop (kill the feeding `tail`) | exit 0; attached channels end with exit code 0. | exit 0. |
| Force stop (SIGTERM) | exit 143. | exit 143. |
| Garbage collection | Both dead run directories removed. | Same. |
| SFTP transport (the Windows channel) against a real sftp-server | — | 2 × 10 concurrent appends under the SFTP `mkdir` lock, all answered. |

## Timings

Milliseconds, one run each. macOS `cold` is the first omp start in a fresh home (it extracts its native
addons); the container's omp had started before. "SSH, 1 s poll" is the first measurement, before followers
passed `-s 0.05` to GNU `tail`; "SSH" is after.

| Step | macOS cold | macOS warm | SSH, 1 s poll | SSH |
|---|---|---|---|---|
| probe | 81 | | 55 | |
| launch (`openRun`, includes the listing that returns the run) | 93 | 73 | 28 | 42 |
| attach (exec `tail -F`, header read) | 19 | 18 | 5 | |
| `ready` after attach | 1,704 | 226 | 1,020 | 402 |
| `get_state` round trip | 27, then 5 | 25, then 5 | 1,002–1,023 | 82–149 |
| 50 pipelined `get_state` | 297 | 291 | 1,936 | 1,313 |
| re-attach | 17 | 15 | 4 | |
| graceful stop to exit file | 83 | 82 | 57 | 65 |
| force stop to exit file | 113 | 89 | 70 | |

The one-second round trips over SSH came from GNU `tail`, not from SSH: on the container's overlayfs it
cannot use inotify and polls once a second (measured directly: 491 ms average from append to output for
`tail -f`, 499 ms for `tail -F`). A round trip passes two tails, the feeder on `in.jsonl` and the follower on
`out.jsonl`. Every tail now gets `-s 0.05` where it accepts it (GNU, BusyBox; BSD `tail` rejects `-s` and
follows with kqueue), which brought the round trip to about 100 ms.

Attached omp (`AttachedChannel`) for comparison: `ready` 314 ms on macOS, 307 ms over SSH; `get_state`
25 ms first, then under 1 ms on macOS; 53 ms first, then 20 ms over SSH.

Uploading the 231 MB `omp-linux-arm64` over dartssh2 SFTP to the container took 140 s and 172 s in two runs
(`uploadOmp`, 4 MiB appends), 1.3 to 1.6 MB/s.

## `tail -F` on a truncated file

`tail -c +1 -F f`, three lines appended, `: > f`, two more lines appended:

| `tail` | Output | stderr |
|---|---|---|
| BSD (macOS 26.6.2) | all five lines, the last two from byte 0 of the new file | `tail: f: file truncated` |
| GNU coreutils 9.4 | same | `tail: f: file truncated` |
| BusyBox 1.37.0 | same | nothing |

All three detect truncation by size, so a file that grows past the reader's position before the next check
is not seen as truncated (BusyBox checks once a second). Rotation therefore happens only while the session
is settled, under the append lock, and writes `{"type":"omp_app_rotate","generation":G,"previousSize":S}` as
the first line of the new generation. A channel that had read exactly `S` bytes continues and counts offsets
from the new file; otherwise its `lines` fail with `RunLogGap` and the device resyncs over RPC.

## Changes to the recipe in PLAN.md §5, and why

1. **No `wait $!` on a background pipeline.** bash (macOS `/bin/sh`) and dash both wait for every member:
   `sh -c 'sleep 5 | sleep 1 & wait $!'` takes 5 s on both. With the PLAN recipe a SIGTERMed omp never got
   its exit code recorded while `tail` lived. `run.sh` now runs
   `tail -f in.jsonl | { omp …; record exit; kill tail; }` in the foreground.
2. **New session.** `run.sh` starts under `setsid` (Linux) or Perl's `POSIX::setsid` (macOS has no `setsid`
   binary). omp installs its own SIGINT, SIGTERM and SIGHUP handlers, so `nohup`'s ignored SIGHUP does not
   protect it; a new session keeps terminal hangups and Ctrl-C of the launching process group away.
3. **`--cwd` is always passed.** omp started in `$HOME` moves itself to `~/tmp`, `/tmp` or `/var/tmp`
   (`cli/startup-cwd.ts`). Measured in the container: a session launched from `/home/omp` recorded
   `"cwd":"/tmp"`.
4. **Follower scripts end on stdin EOF.** sshd does not signal a non-PTY command when its channel closes, so a
   bare `tail -F` would outlive the channel until its next write. Each follower runs
   `tail … & cat >/dev/null; kill $tail`.
5. **In-band markers.** After omp exits, `run.sh` appends `\n{"type":"omp_app_exit","code":N}` to
   `out.jsonl` (the leading newline closes a line omp left unfinished), then writes `exit`. Channels end
   their `lines` there; RPC clients never see the markers.
6. **One appender per channel.** A long-running script appends each line under `mkdir in.lock` (a lock older
   than 30 s is broken) and acknowledges it with `in.jsonl`'s size, which is the line's end offset, so a
   device knows which inbox lines are its own. Lines up to 64 KiB go through the appender's stdin; `sh`'s
   `read` takes a byte per system call on a pipe (64 KiB: 15 ms dash, 33 ms bash; 1 MiB: 372 ms and
   462 ms), so longer lines are uploaded over SFTP and appended with `cat`.
7. **Scripts that read stdin are not started with `sh -s`.** A shell may read ahead on a pipe and swallow the
   data meant for the script, so the first stdin line carries the script's byte count and `dd bs=1` reads
   exactly that.
8. **`tail -s 0.05` where supported.** GNU and BusyBox `tail` fall back to polling once a second without
   inotify, which made every round trip over SSH take a second (see Timings).

## omp facts seen on the way

- `--session <path>` of a file that does not exist creates the session there and writes the title slot and
  header at once (681 bytes before any turn).
- Cold start to `ready` in a fresh home: 1.7 s; warm: 0.23 s (macOS).
- The probe found BusyBox `wget` and `sha256sum` on Alpine, and only `sha256sum` (no curl, no wget) on stock
  Ubuntu 24.04 and Debian 12 images: there, uploading a release asset is the only install route.

## Windows: implemented, not run on Windows

Checked with PowerShell 7.6.4 on macOS (`test/channel/windows_scripts_test.dart`):

- `feed.ps1` copies `in.jsonl` byte for byte (non-ASCII, CRLF, a 200 KB line) and exits once
  `in.jsonl.stop` exists.
- The session listing script returns the same sessions as the POSIX one.
- The probe script reads `PROCESSOR_ARCHITEW6432` before `PROCESSOR_ARCHITECTURE` and finds
  `%LOCALAPPDATA%\omp\omp.exe`.
- Encoded command lengths with realistic paths (limit 8,191): probe 7,035, session listing 7,163, run
  listing 6,247, launch 5,983, kill 1,743 characters. Longer scripts are uploaded and run with `-File`.
- `SftpRunChannel`, the Windows channel, passed its appends-under-lock test against OpenSSH's sftp-server in
  the Linux container and the local file system.

Not verified, because no Windows machine is available:

- `Win32_Process.Create` with `CREATE_BREAKAWAY_FROM_JOB` surviving the SSH channel, and the environment
  block (`USERPROFILE`, `LOCALAPPDATA`, `PATH` passed explicitly from the SSH session).
- cmd.exe `>>` redirection sharing `out.jsonl` with sftp-server reads, and `feed.ps1` sharing `in.jsonl` with
  sftp-server appends.
- Win32-OpenSSH's SFTP append (each append is checked by comparing sizes and fails loudly).
- `run.cmd` taking omp's exit code from `%ERRORLEVEL%` after the pipe, and `chcp`-independent paths (they
  reach cmd.exe only through `OMPAPP_*` environment variables).
- Windows PowerShell 5.1 differences from PowerShell 7; the WMI orphan discovery by command line.

## Risks left open

- systemd-logind with `KillUserProcesses=yes` kills a user's processes when the last session ends, detached
  or not. Untested: the container runs no systemd.
- Rotation while omp writes: a frame omp emits between the truncation and the marker lands before the
  marker, and readers mis-attribute it to the old generation. Rotation is only done while settled.
- A half-open SSH connection keeps its follower scripts until sshd notices; `ClientAliveInterval` defaults
  to 0.
- `meta.json` records the session the run was launched with; after `new_session` or `open_session` inside
  omp the run holds another file, and a device looking for that file launches a second omp.
