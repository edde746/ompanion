// Port of packages/omp_core/lib/src/channel/detached_run.dart.
import { hostProbeIsWindows, type HostProbe } from "../host/probe";
import {
  newMarker,
  posixLockFunctions,
  posixTailPoll,
  runPosixScript,
  scriptResultFailure,
  scriptResultPayload,
  shQuote,
} from "../host/scripts";
import { asJsonObject, FormatException, optString, string, strings, type JsonObject } from "../rpc/json_fields";
import { HostLinkException, type HostLink } from "../transport/host_link";
import { script } from "../util/script";
import { splitLines, tryParseInt } from "../util/text";
import { DetachedChannel } from "./detached_channel";
import type { AttachTools } from "./follow";
import { logLimits, type LogLimits } from "./log_script";
import type { RunChannel } from "./run_log";
import {
  attachWindowsRun,
  listWindowsRuns,
  openWindowsRun,
  recordWindowsRunSession,
  removeWindowsRuns,
  stopWindowsRun,
} from "./windows_run";

/** Forces off what a headless host must not do: `ask` speaking on the host's speaker. */
export const defaultOverlay = "speech:\n  enabled: false\n";

/** What to run: one `omp --mode rpc-ui` process for one session. Paths are host-native. */
export interface RunSpec {
  /** Absolute path of the omp binary (the probed one). */
  readonly omp: string;
  readonly ompVersion: string;
  readonly cwd: string;

  /**
   * The scripts on the machine: a detached run's output goes to `out.jsonl` through [logScript]'s pump, run by
   * [AttachTools.bun].
   */
  readonly tools: AttachTools;

  /** `--session`; absent starts a new session. */
  readonly sessionPath?: string;

  /** `-e`: the companion extension. */
  readonly companion?: string;

  /** YAML written to the run's `overlay.yml` and passed with `--config`. */
  readonly overlay: string;

  /** Further omp arguments, e.g. `['--model', 'fake/fake-1']`. */
  readonly args: readonly string[];

  /**
   * How long the run may sit idle before the companion ends its omp (`OMPANION_IDLE_EXIT_MS`,
   * docs/contracts/host-launch.md); absent keeps it running until it is stopped.
   */
  readonly idleExitMs?: number;

  /** How the pump writes `out.jsonl`. */
  readonly limits: LogLimits;
}

/** Dart's `RunSpec(...)`: [overlay] defaults to [defaultOverlay], [args] to none, [limits] to [logLimits]. */
export function runSpec(
  fields: Omit<RunSpec, "overlay" | "args" | "limits"> & Partial<Pick<RunSpec, "overlay" | "args" | "limits">>,
): RunSpec {
  return {
    ...fields,
    overlay: fields.overlay ?? defaultOverlay,
    args: fields.args ?? [],
    limits: fields.limits ?? logLimits,
  };
}

/**
 * omp's arguments after the binary, given the host path of the overlay file. `--cwd` is explicit because omp started
 * in the home directory otherwise moves itself to `~/tmp` or `/tmp` (`cli/startup-cwd.ts`).
 */
export function runSpecOmpArgs(spec: RunSpec, overlayPath: string): string[] {
  return [
    "--mode",
    "rpc-ui",
    "--config",
    overlayPath,
    "--cwd",
    spec.cwd,
    ...(spec.companion === undefined ? [] : ["-e", spec.companion]),
    ...(spec.sessionPath === undefined ? [] : ["--session", spec.sessionPath]),
    ...spec.args,
  ];
}

/** `meta.json` of a run directory. */
export interface RunMeta {
  readonly id: string;
  readonly cwd: string;
  readonly omp: string;
  readonly ompVersion: string;

  /** omp's arguments after the binary. */
  readonly args: readonly string[];
  readonly createdAt: number;

  /** The session the run was launched with; absent for a run that started a new session. */
  readonly sessionPath?: string;
  readonly companion?: string;
}

export function runMetaFromJson(json: JsonObject): RunMeta {
  const created = string(json, "created");
  const createdAt = Date.parse(created);
  if (Number.isNaN(createdAt)) throw new FormatException(`meta.json: bad created "${created}"`);
  return {
    id: string(json, "id"),
    cwd: string(json, "cwd"),
    omp: string(json, "omp"),
    ompVersion: string(json, "ompVersion"),
    args: strings(json, "args"),
    createdAt,
    sessionPath: optString(json, "sessionPath"),
    companion: optString(json, "companion"),
  };
}

/** Key order and compact encoding are fixed: host scripts match `"sessionPath":<value>,` textually. */
export function runMetaToJson(meta: RunMeta): JsonObject {
  return {
    id: meta.id,
    sessionPath: meta.sessionPath ?? null,
    cwd: meta.cwd,
    omp: meta.omp,
    ompVersion: meta.ompVersion,
    companion: meta.companion ?? null,
    args: meta.args,
    created: new Date(meta.createdAt).toISOString(),
  };
}

/**
 * `running`: omp and its stdin feeder are running. `stopping`: the feeder is gone; omp is draining and will exit.
 * `exited`: omp exited and its exit code was recorded. `dead`: omp is gone without an exit code (killed together with
 * its wrapper, or the machine rebooted).
 */
export type RunState = "running" | "stopping" | "exited" | "dead";

/** A run directory `~/.ompanion/run/<id>/` and the state of its processes. */
export interface DetachedRun {
  readonly id: string;

  /** Host-native path of the run directory. */
  readonly dir: string;
  readonly state: RunState;

  /** Absent when `meta.json` is missing or unreadable (a launch that died half way). */
  readonly meta?: RunMeta;
  readonly ompPid?: number;
  readonly exitCode?: number;
  readonly outSize: number;
  readonly inSize: number;

  /** Last modification of `out.jsonl`. */
  readonly lastWriteAt?: number;
}

export function detachedRunLive(run: DetachedRun): boolean {
  return run.state === "running" || run.state === "stopping";
}

/** Host-native directory holding the run directories. */
export function runRoot(probe: HostProbe): string {
  return hostProbeIsWindows(probe) ? `${probe.home}\\.ompanion\\run` : `${probe.home}/.ompanion/run`;
}

/**
 * Finds the live run of [spec]'s session, or launches one. A launch lock on the machine makes this atomic across
 * devices: two devices opening the same session get the same run. Runs without a session path always launch.
 */
export function openRun(
  link: HostLink,
  probe: HostProbe,
  spec: RunSpec,
): Promise<{ run: DetachedRun; launched: boolean }> {
  return hostProbeIsWindows(probe) ? openWindowsRun(link, probe, spec) : openPosixRun(link, probe, spec);
}

/** Every run directory on the machine, oldest first. */
export function listRuns(link: HostLink, probe: HostProbe): Promise<DetachedRun[]> {
  return hostProbeIsWindows(probe) ? listWindowsRuns(link, probe) : listPosixRuns(link, runRoot(probe));
}

/**
 * Attaches to [run]. `out.jsonl` is read from [offset] when [generation] is still the run's generation, or follows
 * the pump's rotation to the next one when that carried the log from [offset] or before: the channel then starts in
 * [generation] at [offset], as if it had stayed attached. Otherwise the current generation is read from its start, or,
 * over [attachWindow] bytes, compacted on the machine by [logScript] and followed from the offset it names. The log is
 * streamed through [followScript], which sends each image once. [tools] names both scripts and the Bun that runs them.
 * `in.jsonl` is read from [inboxOffset], or from its current end when absent.
 */
export function attachRun(
  link: HostLink,
  probe: HostProbe,
  run: DetachedRun,
  options: { tools: AttachTools; generation?: number; offset?: number; inboxOffset?: number },
): Promise<RunChannel> {
  return hostProbeIsWindows(probe)
    ? attachWindowsRun(link, probe, run, options)
    : DetachedChannel.attach(link, run.dir, options);
}

/**
 * Stops [run] and waits up to [timeoutMs] for omp to exit. A graceful stop closes omp's stdin, after which omp
 * finishes accepted commands, disposes the session and exits 0; [force] sends SIGTERM (POSIX, exit 143) or terminates
 * the process (Windows). Returns the exit code, or undefined when omp is gone without one. Throws
 * [HostLinkException] when omp still runs after [timeoutMs].
 */
export function stopRun(
  link: HostLink,
  probe: HostProbe,
  run: DetachedRun,
  options: { force?: boolean; timeoutMs?: number } = {},
): Promise<number | undefined> {
  const force = options.force ?? false;
  const timeoutMs = options.timeoutMs ?? 30_000;
  return hostProbeIsWindows(probe)
    ? stopWindowsRun(link, probe, run, { force, timeoutMs })
    : stopPosixRun(link, run, { signal: force ? "TERM" : undefined, timeoutMs });
}

/**
 * Ends [run]'s omp at once, before it can write anything: SIGKILL on POSIX, a terminate on Windows (which gets no
 * signal there either). For an omp whose history is a stale fork of its session file: omp's own exit, graceful or on
 * SIGTERM, appends a `session_exit` entry under its old leaf, and the file's next resume continues from that leaf.
 * Returns the exit code, or undefined when omp is gone without one; throws [HostLinkException] when omp still runs
 * after [timeoutMs].
 */
export function killRun(
  link: HostLink,
  probe: HostProbe,
  run: DetachedRun,
  options: { timeoutMs?: number } = {},
): Promise<number | undefined> {
  const timeoutMs = options.timeoutMs ?? 30_000;
  return hostProbeIsWindows(probe)
    ? stopWindowsRun(link, probe, run, { force: true, timeoutMs })
    : stopPosixRun(link, run, { signal: "KILL", timeoutMs });
}

/**
 * Removes the directories of runs that are not live and whose `out.jsonl` was last written more than [olderThanMs]
 * ago. [runs] is the machine's run list when the caller just read it; otherwise it is listed here. The removal checks
 * each run's liveness again under the launch lock. Returns the removed run ids.
 */
export async function removeDeadRuns(
  link: HostLink,
  probe: HostProbe,
  options: { olderThanMs?: number; runs?: readonly DetachedRun[] } = {},
): Promise<string[]> {
  const olderThanMs = options.olderThanMs ?? 0;
  const now = Date.now();
  const dead = (options.runs ?? (await listRuns(link, probe)))
    .filter((run) => !detachedRunLive(run) && (run.lastWriteAt === undefined || now - run.lastWriteAt >= olderThanMs))
    .map((run) => run.id);
  if (dead.length === 0) return [];
  return hostProbeIsWindows(probe)
    ? removeWindowsRuns(link, probe, dead)
    : removePosixRuns(link, runRoot(probe), dead);
}

/**
 * Records [sessionPath] as the session [run] holds in its `meta.json`, so a device opening that session finds this
 * run instead of launching a second omp. omp changes files inside a run (`new_session`, `switch_session`, `branch`,
 * fork), and a run launched without `--session` learns its file from `get_state`. Holds the launch lock, so a launch
 * looking for the session sees either record. Returns whether `meta.json` changed.
 */
export async function recordRunSession(
  link: HostLink,
  probe: HostProbe,
  run: DetachedRun,
  sessionPath: string,
): Promise<boolean> {
  const meta = run.meta;
  if (meta === undefined) throw new HostLinkException(`run ${run.id} has no readable meta.json`);
  const text = JSON.stringify(runMetaToJson({ ...meta, sessionPath }));
  const session = `"sessionPath":${JSON.stringify(sessionPath)},`;
  if (hostProbeIsWindows(probe)) return recordWindowsRunSession(link, probe, run, { session, meta: text });
  const marker = newMarker();
  const result = await runPosixScript(
    link,
    `m=${shQuote(marker)}; R=${shQuote(runRoot(probe))}; d=${shQuote(run.dir)}\n` +
      `session=${shQuote(session)}; meta=${shQuote(text)}\n` +
      `${posixLockFunctions}${recordBody}`,
  );
  if (result.exit.code !== 0) throw scriptResultFailure(result, `recording the session of run ${run.id} failed`);
  return scriptResultPayload(result, marker).trim() === "updated";
}

/** Sortable and unique: UTC time, then 32 random bits. */
export function newRunId(): string {
  const now = new Date().toISOString().replace(/[-:]/g, "").substring(0, 15);
  const random = crypto.getRandomValues(new Uint32Array(1))[0]!;
  return `${now}-${random.toString(16).padStart(8, "0")}`;
}

/**
 * `running <pid> <text>`: the process exists and its command line contains the text, which guards against a recycled
 * pid. busybox `ps` has no `-p`, so Linux reads `/proc`.
 */
const processFunctions = script`cmdline() { if [ -r "/proc/$1/cmdline" ]; then tr '\000' ' ' < "/proc/$1/cmdline"; else ps -p "$1" -o args= 2>/dev/null; fi; }
running() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null && cmdline "$1" | grep -qF "$2"; }
`;

/**
 * `runs <dir>...` prints the run listing [parsePosixRunList] reads. Builtins read each run's files and probe its pids;
 * one `stat` sizes every log and one `ps` (one `tr` per live pid where `/proc` exists) reads the command lines.
 * Commands per run would start about twelve processes per run: measured with 41 runs, 0.7 s on an M5 Pro Mac and
 * 4.1 s on an M3 MacBook Air (10 ms per process start).
 */
const runsFunction = script`runs() {
  rs_csv=; rs_list=
  for rs_d; do
    [ -d "$rs_d" ] || continue
    rs_p=; rs_t=; rs_e=; rs_meta=
    { IFS= read -r rs_p < "$rs_d/omp.pid"; } 2>/dev/null
    { IFS= read -r rs_t < "$rs_d/tail.pid"; } 2>/dev/null
    { IFS= read -r rs_e < "$rs_d/exit"; } 2>/dev/null
    { IFS= read -r rs_meta < "$rs_d/meta.json"; } 2>/dev/null
    printf 'run\t%s\t%s\t%s\t%s\n%s\n' "\${rs_d##*/}" "$rs_p" "$rs_t" "$rs_e" "$rs_meta"
    for rs_x in "$rs_p" "$rs_t"; do
      case $rs_x in '' | 0 | *[!0-9]*) continue ;; esac
      if kill -0 "$rs_x" 2>/dev/null; then rs_csv="$rs_csv\${rs_csv:+,}$rs_x"; rs_list="$rs_list $rs_x"; fi
    done
  done
  printf 'files\n'
  for rs_d; do
    shift
    [ -d "$rs_d" ] || continue
    for rs_x in "$rs_d/out.jsonl" "$rs_d/in.jsonl"; do if [ -f "$rs_x" ]; then set -- "$@" "$rs_x"; fi; done
  done
  if [ $# -gt 0 ]; then
    if stat -c %s / >/dev/null 2>&1; then stat -c '%s %Y %n' "$@"; else stat -f '%z %m %N' "$@"; fi 2>/dev/null
  fi
  printf 'procs\n'
  if [ -z "$rs_csv" ]; then return 0; fi
  if [ -r /proc/self/cmdline ]; then
    for rs_x in $rs_list; do
      printf '%s ' "$rs_x"
      { tr '\000' ' ' < "/proc/$rs_x/cmdline"; } 2>/dev/null
      echo
    done
  else
    ps -o pid=,args= -p "$rs_csv" 2>/dev/null
  fi
  return 0
}
`;

async function openPosixRun(
  link: HostLink,
  probe: HostProbe,
  spec: RunSpec,
): Promise<{ run: DetachedRun; launched: boolean }> {
  const marker = newMarker();
  const root = runRoot(probe);
  const result = await runPosixScript(
    link,
    posixLaunchScript(marker, root, newRunId(), spec, { loginPath: probe.loginPath }),
  );
  if (result.exit.code !== 0) throw scriptResultFailure(result, `launching omp in ${spec.cwd} failed`);
  const payload = scriptResultPayload(result, marker);
  const reply = (payload.split("\n")[0] ?? "").split(" ");
  if (reply.length !== 2) throw scriptResultFailure(result, `unexpected launch reply "${reply.join(" ")}"`);
  // The reply's first line names the run; the run listing of that one directory follows.
  const listed = parsePosixRunList(payload.substring(payload.indexOf("\n") + 1), root);
  const run = listed.length === 1 ? listed[0] : undefined;
  if (run === undefined || run.id !== reply[1]) {
    throw scriptResultFailure(result, `the launch reply does not list run ${reply[1]}`);
  }
  return { run, launched: reply[0] === "launched" };
}

/**
 * The launch recipe. `run.sh` feeds omp with `tail -f in.jsonl` and pipes its stdout through the pump into
 * `out.jsonl`; it is started in a new session (`setsid`, or Perl's on macOS, which has no `setsid` binary) so neither a
 * terminal hangup nor a Ctrl-C in the launching process group reaches omp, and every descriptor points at
 * run-directory files, so the launching channel can close. `umask 077` is for the run directory only: `run.sh` starts
 * with the launching shell's umask, so the files omp and its tools create get the same permissions as under an
 * attached omp. [loginPath] is the login shell's PATH ([HostProbe.loginPath]): it goes in front of omp's own PATH, and
 * only there — the wrapper's `tail`, `ps` and `mkdir` keep resolving through the PATH sshd gave this script. The reply
 * is `launched <id>` or `found <id>`, then that run's listing (`runs`), so opening a run reads no other run directory.
 */
export function posixLaunchScript(
  marker: string,
  root: string,
  id: string,
  spec: RunSpec,
  options: { loginPath?: string } = {},
): string {
  const dir = `${root}/${id}`;
  const args = runSpecOmpArgs(spec, `${dir}/overlay.yml`);
  const meta: RunMeta = {
    id,
    cwd: spec.cwd,
    omp: spec.omp,
    ompVersion: spec.ompVersion,
    args,
    createdAt: Date.now(),
    sessionPath: spec.sessionPath,
    companion: spec.companion,
  };
  const session = spec.sessionPath === undefined ? "" : `"sessionPath":${JSON.stringify(spec.sessionPath)},`;
  const overlay = spec.overlay.endsWith("\n") ? spec.overlay : `${spec.overlay}\n`;
  const runsh = posixRunScript(dir, spec.omp, args, {
    tools: spec.tools,
    limits: spec.limits,
    loginPath: options.loginPath,
    idleExitMs: spec.idleExitMs,
  });
  return `m=${shQuote(marker)}; R=${shQuote(root)}; D=${shQuote(dir)}; cwd=${shQuote(spec.cwd)}; session=${shQuote(session)}
overlay=${shQuote(overlay)}
meta=${shQuote(JSON.stringify(runMetaToJson(meta)))}
runsh=${shQuote(runsh)}
${posixLockFunctions}${processFunctions}${runsFunction}${launchBody}`;
}

/**
 * `run.sh`: the pipeline's right side runs omp, records its exit code in `code`, and pipes its stdout through the
 * pump ([logScript], the only writer of `out.jsonl` while omp runs); then it records the exit code in `exit` and, as
 * the last line, in `out.jsonl`. The feeding `tail` would only notice omp's death at its next write, so that side kills
 * it too. (`wait $!` cannot be used: bash and dash wait for the whole background pipeline.) [loginPath], the login
 * shell's PATH, reaches omp as `$1` of the inner `sh -c` and is prepended there: the pipeline's own commands keep the
 * PATH sshd gave `run.sh`. With [idleExitMs], omp gets the run directory and the idle time in its environment.
 * `BUN_BE_BUN` reaches the pump alone. Both inner shells get the path that identifies their process (`in.jsonl`,
 * `overlay.yml`) as an argument, so a command line names it as soon as the pid file exists, before `exec`.
 */
export function posixRunScript(
  dir: string,
  omp: string,
  args: readonly string[],
  options: { tools: AttachTools; limits: LogLimits; loginPath?: string; idleExitMs?: number },
): string {
  const idle =
    options.idleExitMs === undefined ? "" : `OMPANION_RUN="$d" OMPANION_IDLE_EXIT_MS=${options.idleExitMs} `;
  const pump = [options.tools.bun, options.tools.log, "pump"].map(shQuote).join(" ");
  return `d=${shQuote(dir)}
${processFunctions}
${posixTailPoll}
sh -c 'echo $$ > "$0/tail.pid"; exec tail $1 -c +1 -f "$2"' "$d" "$tailpoll" "$d/in.jsonl" 2>/dev/null | {
  { ${idle}sh -c '${ompExecBody}' "$d" ${shQuote(options.loginPath ?? "")} ${[omp, ...args].map(shQuote).join(" ")} 2>> "$d/err.log"; echo $? > "$d/code"; } |
    BUN_BE_BUN=1 ${pump} "$d" ${pumpArguments(options.limits)} 2>> "$d/err.log"
${runTail}}
`;
}

/** The pump's arguments after the run directory: [LogLimits] as `log.js pump` takes them. */
export function pumpArguments(limits: LogLimits): string {
  return `${limits.rotateAt} ${limits.carry} ${limits.holdMs} ${limits.markEvery} ${limits.progressRate}`;
}

/**
 * The command the pipeline's right side runs omp with, after `$0` (the run directory) and `$1` (the login shell's
 * PATH, empty when the probe read none): omp's pid goes into `omp.pid` first, so the pid file names the process `exec`
 * leaves behind.
 */
const ompExecBody = 'echo $$ > "$0/omp.pid"; if [ -n "$1" ]; then PATH="$1:$PATH"; export PATH; fi; shift; exec "$@"';

const runTail = script`  code=$(cat "$d/code" 2>/dev/null); code=\${code:--1}
  i=0
  while [ ! -s "$d/tail.pid" ] && [ $i -lt 100 ]; do sleep 0.01 2>/dev/null || sleep 1; i=$((i + 1)); done
  t=$(cat "$d/tail.pid" 2>/dev/null)
  if running "$t" "$d/in.jsonl"; then kill "$t"; fi
  printf '\n{"type":"ompanion_exit","code":%d}\n' "$code" >> "$d/out.jsonl"
  printf '%d\n' "$code" > "$d/exit.tmp" && mv -f "$d/exit.tmp" "$d/exit"
`;

const launchBody = script`u=$(umask)
umask 077
mkdir -p "$R" || exit 1
chmod 700 "\${R%/*}" "$R"
cd "$cwd" || { echo "cannot enter $cwd" >&2; exit 1; }
lock "$R/.launch.lock" 60 || exit 1
trap 'unlock "$R/.launch.lock"' EXIT
if [ -n "$session" ]; then
  for x in "$R"/*; do
    [ -f "$x/meta.json" ] || continue
    grep -qF "$session" "$x/meta.json" || continue
    if running "$(cat "$x/omp.pid" 2>/dev/null)" "$x/overlay.yml" && running "$(cat "$x/tail.pid" 2>/dev/null)" "$x/in.jsonl"; then
      printf '%s:begin\nfound %s\n' "$m" "\${x##*/}"
      runs "$x"
      printf '%s:end\n' "$m"
      exit 0
    fi
  done
fi
mkdir "$D" || exit 1
printf '%s' "$overlay" > "$D/overlay.yml"
printf '%s\n' "$meta" > "$D/meta.json"
printf 'umask %s\n%s' "$u" "$runsh" > "$D/run.sh"
: > "$D/in.jsonl"; : > "$D/out.jsonl"; : > "$D/err.log"
if command -v setsid >/dev/null 2>&1; then
  setsid sh "$D/run.sh" </dev/null >/dev/null 2>&1 &
elif command -v perl >/dev/null 2>&1; then
  perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV or die "exec: $!\n"' sh "$D/run.sh" </dev/null >/dev/null 2>&1 &
else
  nohup sh "$D/run.sh" </dev/null >/dev/null 2>&1 &
fi
i=0
while { [ ! -s "$D/omp.pid" ] || [ ! -s "$D/tail.pid" ]; } && [ $i -lt 1000 ]; do
  sleep 0.01 2>/dev/null || sleep 1
  i=$((i + 1))
done
if [ ! -s "$D/omp.pid" ]; then echo "omp did not start; see $D/err.log" >&2; exit 1; fi
printf '%s:begin\nlaunched %s\n' "$m" "\${D##*/}"
runs "$D"
printf '%s:end\n' "$m"
`;

async function listPosixRuns(link: HostLink, root: string): Promise<DetachedRun[]> {
  const marker = newMarker();
  const result = await runPosixScript(link, `m=${shQuote(marker)}; R=${shQuote(root)}\n${runsFunction}${listBody}`);
  if (result.exit.code !== 0) throw scriptResultFailure(result, "listing runs failed");
  return parsePosixRunList(scriptResultPayload(result, marker), root);
}

const listBody = script`printf '%s:begin\n' "$m"
runs "$R"/*
printf '%s:end\n' "$m"
`;

/**
 * Parses the POSIX run listing (`runs`): two lines per run, `run<TAB>id<TAB>omp pid<TAB>feeder pid<TAB>exit code` and
 * the first line of its `meta.json`; then a `files` line and `<size> <mtime> <path>` per log; then a `procs` line and
 * `<pid> <command line>` per live pid. omp runs while its pid's command line names the run's `overlay.yml`, the feeder
 * while its pid's names the run's `in.jsonl`; a recycled pid names neither.
 */
export function parsePosixRunList(payload: string, root: string): DetachedRun[] {
  const lines = splitLines(payload);
  let i = 0;
  const rows: Array<[string[], string]> = [];
  for (; i < lines.length && lines[i] !== "files"; i += 2) {
    const fields = lines[i]!.split("\t");
    if (fields.length !== 5 || fields[0] !== "run" || i + 1 === lines.length) {
      throw new FormatException(`run list: bad line "${lines[i]}"`);
    }
    rows.push([fields, lines[i + 1]!]);
  }
  if (i === lines.length) throw new FormatException("run list: no files section");
  const files = new Map<string, { size: number; mtime: number }>();
  for (i++; i < lines.length && lines[i] !== "procs"; i++) {
    const match = /^(\d+) (\d+) (.+)$/.exec(lines[i]!);
    if (match === null) throw new FormatException(`run list: bad file line "${lines[i]}"`);
    files.set(match[3]!, { size: Number(match[1]), mtime: Number(match[2]) });
  }
  if (i === lines.length) throw new FormatException("run list: no procs section");
  const commands = new Map<number, string>();
  let last: number | undefined;
  for (i++; i < lines.length; i++) {
    const match = /^\s*(\d+) ?(.*)$/.exec(lines[i]!);
    if (match !== null) {
      last = Number(match[1]);
      commands.set(last, match[2]!);
    } else if (last !== undefined) {
      // An argument holding a newline continues the previous command line.
      commands.set(last, `${commands.get(last)}\n${lines[i]}`);
    } else {
      throw new FormatException(`run list: bad process line "${lines[i]}"`);
    }
  }
  const names = (pid: string, path: string): boolean => {
    const number = tryParseInt(pid);
    return number !== undefined && (commands.get(number)?.includes(path) ?? false);
  };
  const runs: DetachedRun[] = [];
  for (const [fields, meta] of rows) {
    const id = fields[1]!;
    const dir = `${root}/${id}`;
    const exitCode = tryParseInt(fields[4]);
    const out = files.get(`${dir}/out.jsonl`);
    const omp = names(fields[2]!, `${dir}/overlay.yml`);
    const feeder = names(fields[3]!, `${dir}/in.jsonl`);
    runs.push({
      id,
      dir,
      state: omp ? (feeder ? "running" : "stopping") : exitCode !== undefined ? "exited" : "dead",
      meta: parseRunMeta(meta),
      ompPid: tryParseInt(fields[2]),
      exitCode,
      outSize: out?.size ?? 0,
      inSize: files.get(`${dir}/in.jsonl`)?.size ?? 0,
      lastWriteAt: out === undefined ? undefined : out.mtime * 1000,
    });
  }
  runs.sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
  return runs;
}

/** A run's `meta.json` text; undefined when it is missing or was cut short by a launch that died. */
export function parseRunMeta(text: string | undefined): RunMeta | undefined {
  if (text === undefined || text.trim() === "") return undefined;
  try {
    return runMetaFromJson(asJsonObject(JSON.parse(text), "meta.json"));
  } catch (error) {
    if (error instanceof SyntaxError || error instanceof FormatException) return undefined;
    throw error;
  }
}

/** [signal] (`TERM`, `KILL`) is sent to omp; without one, omp's stdin is closed. */
async function stopPosixRun(
  link: HostLink,
  run: DetachedRun,
  options: { signal: string | undefined; timeoutMs: number },
): Promise<number | undefined> {
  const marker = newMarker();
  const result = await runPosixScript(
    link,
    `m=${shQuote(marker)}; d=${shQuote(run.dir)}; signal=${options.signal ?? ""}; ticks=${Math.trunc(options.timeoutMs / 50)}\n` +
      `${posixLockFunctions}${processFunctions}${stopBody}`,
  );
  if (result.exit.code !== 0) throw scriptResultFailure(result, `stopping run ${run.id} failed`);
  const reply = scriptResultPayload(result, marker).trim().split(" ");
  if (reply[0] === "running") {
    throw new HostLinkException(`omp of run ${run.id} still runs after ${options.timeoutMs} ms`);
  }
  return reply.length > 1 ? tryParseInt(reply[1]) : undefined;
}

/** Waits for the `exit` file; gives up early once omp has been gone for a second without one being written. */
const stopBody = script`p=$(cat "$d/omp.pid" 2>/dev/null)
if [ -n "$signal" ]; then
  if running "$p" "$d/overlay.yml"; then kill -"$signal" "$p"; fi
else
  t=$(cat "$d/tail.pid" 2>/dev/null)
  if running "$t" "$d/in.jsonl"; then kill "$t"; fi
fi
i=0; gone=0
while [ ! -f "$d/exit" ] && [ $i -lt "$ticks" ] && [ $gone -lt 20 ]; do
  if running "$p" "$d/overlay.yml"; then gone=0; else gone=$((gone + 1)); fi
  sleep 0.05 2>/dev/null || sleep 1
  i=$((i + 1))
done
s=gone; if running "$p" "$d/overlay.yml"; then s=running; fi
printf '%s:begin\n%s %s\n%s:end\n' "$m" "$s" "$(cat "$d/exit" 2>/dev/null)" "$m"
`;

async function removePosixRuns(link: HostLink, root: string, ids: readonly string[]): Promise<string[]> {
  const marker = newMarker();
  const result = await runPosixScript(
    link,
    `m=${shQuote(marker)}; R=${shQuote(root)}\nset -- ${ids.map(shQuote).join(" ")}\n` +
      `${posixLockFunctions}${processFunctions}${removeBody}`,
  );
  if (result.exit.code !== 0) throw scriptResultFailure(result, "removing runs failed");
  return splitLines(scriptResultPayload(result, marker)).filter((line) => line !== "");
}

/**
 * Holds the launch lock, so no device launches into or finds a directory being removed, and re-checks liveness under
 * it. A feeder left behind by a killed wrapper is stopped first.
 */
const removeBody = script`lock "$R/.launch.lock" 60 || exit 1
trap 'unlock "$R/.launch.lock"' EXIT
printf '%s:begin\n' "$m"
for id in "$@"; do
  case $id in ''|.*|*/*) continue ;; esac
  d="$R/$id"
  [ -d "$d" ] || continue
  if running "$(cat "$d/omp.pid" 2>/dev/null)" "$d/overlay.yml"; then continue; fi
  t=$(cat "$d/tail.pid" 2>/dev/null)
  if running "$t" "$d/in.jsonl"; then kill "$t"; fi
  rm -rf "$d" && printf '%s\n' "$id"
done
printf '%s:end\n' "$m"
`;

/** Under the launch lock, so a launch looking for the session sees the old record or the new one. */
const recordBody = script`lock "$R/.launch.lock" 60 || exit 1
trap 'unlock "$R/.launch.lock"' EXIT
r=same
if ! grep -qF "$session" "$d/meta.json"; then
  printf '%s\n' "$meta" > "$d/meta.json.tmp" && mv -f "$d/meta.json.tmp" "$d/meta.json" || exit 1
  r=updated
fi
printf '%s:begin\n%s\n%s:end\n' "$m" "$r" "$m"
`;
