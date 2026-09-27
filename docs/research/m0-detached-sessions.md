# M0: detached sessions on POSIX hosts, Windows scripts

The POSIX detached session works on macOS and Linux with omp 18.3.1. omp outlives the process and the SSH
connection that launched it. Devices re-attach from a saved byte offset and get only newer lines. Concurrent
appenders never interleave. Rotation is followed by BSD and GNU `tail`. A graceful stop exits 0 in about
80 ms. The Windows form runs in CI on Windows Server 2025; appending over SFTP failed there and was replaced
by a PowerShell appender (see Windows below).

Measured on 2026-09-25 with the omp 18.3.1 release binaries, isolated homes (`harness/omp-home.sh`) and no
model turn.

| Host | Shell (`/bin/sh`) | `tail` | Reached through |
|---|---|---|---|
| this Mac, macOS 26.6.2 | bash 3.2.57 in POSIX mode | BSD | `LocalLink` |
| Ubuntu 24.04.4 container (aarch64, colima) | dash | GNU coreutils 9.4 | `SshLink` (dartssh2 4.1.0) to OpenSSH 9.6p1 |
| Alpine container (probe, listing, `tail`) | BusyBox 1.37.0 | BusyBox | `docker run -i … sh -s` |

Code: `packages/omp_core/lib/src/channel/`. Tests: `test/channel/detached_omp_test.dart`
(`dart test -P integration -t omp`) and `test/channel/detached_docker_test.dart` (`-t docker`, after
`harness/sshd/up.sh`).

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
follows with kqueue), which brought the round trip to about 100 ms. BSD `tail -F` copies byte by byte
(`getc`/`putchar`) at about 15 MB/s (20 MB in 1.36 s), a plain `tail -c +N` sends the same 20 MB in 15 ms: the
follower sends what `out.jsonl` already holds with a plain `tail`, then follows with `tail -F`. A Perl loop
reading 1 MiB blocks was as fast but polled: 5–25 ms per line against 0.3–0.6 ms for `tail -F`.

Attached omp (`AttachedChannel`) for comparison: `ready` 314 ms on macOS, 307 ms over SSH; `get_state`
25 ms first, then under 1 ms on macOS; 53 ms first, then 20 ms over SSH.

Uploading the 231 MB `omp-linux-arm64` over dartssh2 SFTP to the container took 140 s and 172 s in two runs
(`uploadOmp`, 4 MiB appends), 1.3 to 1.6 MB/s. dartssh2's pure-Dart ciphers bound such transfers: AES-GCM, then
first in its list, reads 0.8–1.2 MB/s from the container on an M-series Mac, chacha20-poly1305 13.8 MB/s (4–7.6 MB
`exec` reads). The link now prefers chacha20-poly1305.

## `tail -F` on a truncated file

`tail -c +1 -F f`, three lines appended, `: > f`, two more lines appended:

| `tail` | Output | stderr |
|---|---|---|
| BSD (macOS 26.6.2) | all five lines, the last two from byte 0 of the new file | `tail: f: file truncated` |
| GNU coreutils 9.4 | same | `tail: f: file truncated` |
| BusyBox 1.37.0 | same | nothing |

All three detect truncation by size, so a file that grows past the reader's position before the next check
is not seen as truncated (BusyBox checks once a second). Rotation therefore happens only while the session
is settled, under the append lock, and writes `{"type":"ompanion_rotate","generation":G,"previousSize":S}` as
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
5. **In-band markers.** After omp exits, `run.sh` appends `\n{"type":"ompanion_exit","code":N}` to
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

## Windows: run in CI

CI's Windows host job (`packages/omp_core/test/windows/`) runs on `windows-latest` (Windows Server 2025, OpenSSH
for Windows 9.5p2) over dartssh2 against the runner's own sshd, with cmd.exe and with PowerShell as the default
shell: probe, exec, long scripts uploaded and run with `-File`, the download install, the file browser's SFTP
operations, attachments in 4 MiB appends, image fetches with an ffmpeg preview, and detached runs with the fake provider (launch
through WMI, reply, a second device, reattach, graceful stop with exit 0, 2 × 10 concurrent appends plus a
200 KB line from two connections).

- Win32-OpenSSH's sftp-server cannot append to `in.jsonl` while omp runs. `fileio_open` opens `O_WRONLY` with
  `FILE_SHARE_WRITE` only (and `O_RDWR` with no sharing), so the open fails against `feed.ps1`'s read handle
  with `ERROR_SHARING_VIOLATION`; its log shows `failed to open file:… error:32`, the client gets status 4
  (`Failure`). Appends go through a PowerShell appender instead (PLAN.md, Windows hosts).
- Windows PowerShell 5.1's `[Console]::OpenStandardInput()` stream returns the first read from the SSH
  channel's stdin pipe and then blocks for good, locally as over sshd (`[Console]::In` too); PowerShell 7 reads
  on. A `FileStream` on the same handle reads every line and sees the end of stdin, so the appender wraps it.
- SFTP reads of `out.jsonl` and `in.jsonl` share with cmd.exe's `>>` and `feed.ps1`: `O_RDONLY` opens with
  `FILE_SHARE_READ | FILE_SHARE_WRITE`.

Checked with PowerShell 7.6.4 on macOS (`test/channel/windows_scripts_test.dart`): `feed.ps1` byte for byte
(non-ASCII, CRLF, a 200 KB line); the session listing script against the POSIX one; the probe under WOW64.
Encoded command lengths with realistic paths (limit 8,191): probe 7,035, session listing 7,163, run listing
6,247, launch 5,983, kill 1,743 characters.

Not verified: a Windows machine whose OpenSSH default shell is Git Bash or another POSIX shell; ARM64
Windows; OpenSSH versions other than 9.5p2.

## Risks left open

- systemd-logind with `KillUserProcesses=yes` kills a user's processes when the last session ends, detached
  or not. Untested: the container runs no systemd.
- Rotation while omp writes: a frame omp emits between the truncation and the marker lands before the
  marker, and readers mis-attribute it to the old generation. Rotation is only done while settled.
- A half-open SSH connection keeps its follower scripts until sshd notices; `ClientAliveInterval` defaults
  to 0.
- `meta.json` records the session the run holds. `MachineRuntime` rewrites it (`recordRunSession`) after every
  session switch it sees; a switch made while no device is attached is recorded only when a device attaches
  and reads `get_state`, so until then a device looking for the new file launches a second omp.
