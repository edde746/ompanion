import 'dart:convert';
import 'dart:math';

import '../host/probe.dart';
import '../host/scripts.dart';
import '../rpc/json_fields.dart';
import '../transport/host_link.dart';
import 'detached_channel.dart';
import 'follow.dart';
import 'log_script.dart';
import 'run_log.dart';
import 'windows_run.dart';

/// Forces off what a headless host must not do: `ask` speaking on the host's speaker.
const defaultOverlay = 'speech:\n  enabled: false\n';

/// What to run: one `omp --mode rpc-ui` process for one session. Paths are host-native.
final class RunSpec {
  const RunSpec({
    required this.omp,
    required this.ompVersion,
    required this.cwd,
    required this.tools,
    this.sessionPath,
    this.companion,
    this.overlay = defaultOverlay,
    this.args = const [],
    this.idleExit,
    this.limits = logLimits,
  });

  /// Absolute path of the omp binary (the probed one).
  final String omp;
  final String ompVersion;
  final String cwd;

  /// The scripts on the machine: a detached run's output goes to `out.jsonl` through [logScript]'s pump, run by
  /// [AttachTools.omp] as Bun.
  final AttachTools tools;

  /// `--session`; null starts a new session.
  final String? sessionPath;

  /// `-e`: the companion extension.
  final String? companion;

  /// YAML written to the run's `overlay.yml` and passed with `--config`.
  final String overlay;

  /// Further omp arguments, e.g. `['--model', 'fake/fake-1']`.
  final List<String> args;

  /// How long the run may sit idle before the companion ends its omp (`OMPANION_IDLE_EXIT_MS`,
  /// docs/contracts/host-launch.md); null keeps it running until it is stopped.
  final Duration? idleExit;

  /// How the pump writes `out.jsonl`.
  final LogLimits limits;

  /// omp's arguments after the binary, given the host path of the overlay file. `--cwd` is explicit because
  /// omp started in the home directory otherwise moves itself to `~/tmp` or `/tmp` (`cli/startup-cwd.ts`).
  List<String> ompArgs(String overlayPath) => [
    '--mode',
    'rpc-ui',
    '--config',
    overlayPath,
    '--cwd',
    cwd,
    if (companion case final companion?) ...['-e', companion],
    if (sessionPath case final session?) ...['--session', session],
    ...args,
  ];
}

/// `meta.json` of a run directory.
final class RunMeta {
  const RunMeta({
    required this.id,
    required this.cwd,
    required this.omp,
    required this.ompVersion,
    required this.args,
    required this.created,
    this.sessionPath,
    this.companion,
  });

  factory RunMeta.fromJson(Map<String, Object?> json) => RunMeta(
    id: json.string('id'),
    cwd: json.string('cwd'),
    omp: json.string('omp'),
    ompVersion: json.string('ompVersion'),
    args: json.strings('args'),
    created: DateTime.parse(json.string('created')),
    sessionPath: json.optString('sessionPath'),
    companion: json.optString('companion'),
  );

  final String id;
  final String cwd;
  final String omp;
  final String ompVersion;

  /// omp's arguments after the binary.
  final List<String> args;
  final DateTime created;

  /// The session the run was launched with; null for a run that started a new session.
  final String? sessionPath;
  final String? companion;

  /// Key order and compact encoding are fixed: host scripts match `"sessionPath":<value>,` textually.
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionPath': sessionPath,
    'cwd': cwd,
    'omp': omp,
    'ompVersion': ompVersion,
    'companion': companion,
    'args': args,
    'created': created.toUtc().toIso8601String(),
  };
}

enum RunState {
  /// omp and its stdin feeder are running.
  running,

  /// The feeder is gone; omp is draining and will exit.
  stopping,

  /// omp exited and its exit code was recorded.
  exited,

  /// omp is gone without an exit code (killed together with its wrapper, or the machine rebooted).
  dead,
}

/// A run directory `~/.ompanion/run/<id>/` and the state of its processes.
final class DetachedRun {
  const DetachedRun({
    required this.id,
    required this.dir,
    required this.state,
    this.meta,
    this.ompPid,
    this.exitCode,
    this.outSize = 0,
    this.inSize = 0,
    this.lastWrite,
  });

  final String id;

  /// Host-native path of the run directory.
  final String dir;
  final RunState state;

  /// Null when `meta.json` is missing or unreadable (a launch that died half way).
  final RunMeta? meta;
  final int? ompPid;
  final int? exitCode;
  final int outSize;
  final int inSize;

  /// Last modification of `out.jsonl`.
  final DateTime? lastWrite;

  bool get live => state == RunState.running || state == RunState.stopping;
}

/// Host-native directory holding the run directories.
String runRoot(HostProbe probe) => probe.isWindows ? '${probe.home}\\.ompanion\\run' : '${probe.home}/.ompanion/run';

/// Finds the live run of [spec]'s session, or launches one. A launch lock on the machine makes this atomic
/// across devices: two devices opening the same session get the same run. Runs without a session path
/// always launch.
Future<({DetachedRun run, bool launched})> openRun(HostLink link, HostProbe probe, RunSpec spec) =>
    probe.isWindows ? openWindowsRun(link, probe, spec) : _openPosixRun(link, probe, spec);

/// Every run directory on the machine, oldest first.
Future<List<DetachedRun>> listRuns(HostLink link, HostProbe probe) =>
    probe.isWindows ? listWindowsRuns(link, probe) : _listPosixRuns(link, runRoot(probe));

/// Attaches to [run]. `out.jsonl` is read from [offset] when [generation] is still the run's generation. Otherwise
/// the current generation is read from its start, or, over [attachWindow] bytes, compacted on the machine by
/// [logScript] and followed from the offset it names. The log is streamed through [followScript], which sends each
/// image once. [tools] names both scripts and the omp that runs them. `in.jsonl` is read from [inboxOffset], or
/// from its current end when null.
Future<RunChannel> attachRun(
  HostLink link,
  HostProbe probe,
  DetachedRun run, {
  required AttachTools tools,
  int? generation,
  int offset = 0,
  int? inboxOffset,
}) => probe.isWindows
    ? attachWindowsRun(link, probe, run, tools: tools, generation: generation, offset: offset, inboxOffset: inboxOffset)
    : DetachedChannel.attach(
        link,
        run.dir,
        tools: tools,
        generation: generation,
        offset: offset,
        inboxOffset: inboxOffset,
      );

/// Stops [run] and waits up to [timeout] for omp to exit. A graceful stop closes omp's stdin, after which
/// omp finishes accepted commands, disposes the session and exits 0; [force] sends SIGTERM (POSIX, exit
/// 143) or terminates the process (Windows). Returns the exit code, or null when omp is gone without one.
/// Throws [HostLinkException] when omp still runs after [timeout].
Future<int?> stopRun(
  HostLink link,
  HostProbe probe,
  DetachedRun run, {
  bool force = false,
  Duration timeout = const Duration(seconds: 30),
}) => probe.isWindows
    ? stopWindowsRun(link, probe, run, force: force, timeout: timeout)
    : _stopPosixRun(link, run, signal: force ? 'TERM' : null, timeout: timeout);

/// Ends [run]'s omp at once, before it can write anything: SIGKILL on POSIX, a terminate on Windows (which gets no
/// signal there either). For an omp whose history is a stale fork of its session file: omp's own exit, graceful or on
/// SIGTERM, appends a `session_exit` entry under its old leaf, and the file's next resume continues from that leaf.
/// Returns the exit code, or null when omp is gone without one; throws [HostLinkException] when omp still runs
/// after [timeout].
Future<int?> killRun(
  HostLink link,
  HostProbe probe,
  DetachedRun run, {
  Duration timeout = const Duration(seconds: 30),
}) => probe.isWindows
    ? stopWindowsRun(link, probe, run, force: true, timeout: timeout)
    : _stopPosixRun(link, run, signal: 'KILL', timeout: timeout);

/// Removes the directories of runs that are not live and whose `out.jsonl` was last written more than
/// [olderThan] ago. [runs] is the machine's run list when the caller just read it; otherwise it is listed here. The
/// removal checks each run's liveness again under the launch lock. Returns the removed run ids.
Future<List<String>> removeDeadRuns(
  HostLink link,
  HostProbe probe, {
  Duration olderThan = Duration.zero,
  List<DetachedRun>? runs,
}) async {
  final now = DateTime.now();
  final dead = [
    for (final run in runs ?? await listRuns(link, probe))
      if (!run.live && (run.lastWrite == null || now.difference(run.lastWrite!) >= olderThan)) run.id,
  ];
  if (dead.isEmpty) return const [];
  return probe.isWindows ? removeWindowsRuns(link, probe, dead) : _removePosixRuns(link, runRoot(probe), dead);
}

/// Records [sessionPath] as the session [run] holds in its `meta.json`, so a device opening that session finds this
/// run instead of launching a second omp. omp changes files inside a run (`new_session`, `switch_session`,
/// `branch`, fork), and a run launched without `--session` learns its file from `get_state`. Holds the launch lock,
/// so a launch looking for the session sees either record. Returns whether `meta.json` changed.
Future<bool> recordRunSession(HostLink link, HostProbe probe, DetachedRun run, String sessionPath) async {
  final meta = run.meta;
  if (meta == null) throw HostLinkException('run ${run.id} has no readable meta.json');
  final text = jsonEncode(_withSession(meta, sessionPath).toJson());
  final session = '"sessionPath":${jsonEncode(sessionPath)},';
  if (probe.isWindows) return recordWindowsRunSession(link, probe, run, session: session, meta: text);
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    'm=${shQuote(marker)}; R=${shQuote(runRoot(probe))}; d=${shQuote(run.dir)}\n'
    'session=${shQuote(session)}; meta=${shQuote(text)}\n'
    '$posixLockFunctions$_recordBody',
  );
  if (result.exit.code != 0) throw result.failure('recording the session of run ${run.id} failed');
  return result.payload(marker).trim() == 'updated';
}

RunMeta _withSession(RunMeta meta, String sessionPath) => RunMeta(
  id: meta.id,
  cwd: meta.cwd,
  omp: meta.omp,
  ompVersion: meta.ompVersion,
  args: meta.args,
  created: meta.created,
  sessionPath: sessionPath,
  companion: meta.companion,
);

final _random = Random.secure();

/// Sortable and unique: UTC time, then 32 random bits.
String newRunId() {
  final now = DateTime.now().toUtc().toIso8601String().replaceAll(RegExp(r'[-:]'), '').substring(0, 15);
  return '$now-${_random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';
}

/// `running <pid> <text>`: the process exists and its command line contains the text, which guards against
/// a recycled pid. busybox `ps` has no `-p`, so Linux reads `/proc`.
const _processFunctions = r'''
cmdline() { if [ -r "/proc/$1/cmdline" ]; then tr '\000' ' ' < "/proc/$1/cmdline"; else ps -p "$1" -o args= 2>/dev/null; fi; }
running() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null && cmdline "$1" | grep -qF "$2"; }
''';

/// `runs <dir>...` prints the run listing [parsePosixRunList] reads. Builtins read each run's files and probe its pids;
/// one `stat` sizes every log and one `ps` (one `tr` per live pid where `/proc` exists) reads the command lines. Commands
/// per run would start about twelve processes per run: measured with 41 runs, 0.7 s on an M5 Pro Mac and 4.1 s on an
/// M3 MacBook Air (10 ms per process start).
const _runsFunction = r'''
runs() {
  rs_csv=; rs_list=
  for rs_d; do
    [ -d "$rs_d" ] || continue
    rs_p=; rs_t=; rs_e=; rs_meta=
    { IFS= read -r rs_p < "$rs_d/omp.pid"; } 2>/dev/null
    { IFS= read -r rs_t < "$rs_d/tail.pid"; } 2>/dev/null
    { IFS= read -r rs_e < "$rs_d/exit"; } 2>/dev/null
    { IFS= read -r rs_meta < "$rs_d/meta.json"; } 2>/dev/null
    printf 'run\t%s\t%s\t%s\t%s\n%s\n' "${rs_d##*/}" "$rs_p" "$rs_t" "$rs_e" "$rs_meta"
    for rs_x in "$rs_p" "$rs_t"; do
      case $rs_x in '' | 0 | *[!0-9]*) continue ;; esac
      if kill -0 "$rs_x" 2>/dev/null; then rs_csv="$rs_csv${rs_csv:+,}$rs_x"; rs_list="$rs_list $rs_x"; fi
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
''';

Future<({DetachedRun run, bool launched})> _openPosixRun(HostLink link, HostProbe probe, RunSpec spec) async {
  final marker = newMarker();
  final root = runRoot(probe);
  final result = await runPosixScript(
    link,
    posixLaunchScript(marker, root, newRunId(), spec, loginPath: probe.loginPath),
  );
  if (result.exit.code != 0) throw result.failure('launching omp in ${spec.cwd} failed');
  final payload = result.payload(marker);
  final reply = payload.split('\n').first.split(' ');
  if (reply.length != 2) throw result.failure('unexpected launch reply "${reply.join(' ')}"');
  // The reply's first line names the run; the run listing of that one directory follows.
  final run = parsePosixRunList(payload.substring(payload.indexOf('\n') + 1), root).singleOrNull;
  if (run == null || run.id != reply[1]) throw result.failure('the launch reply does not list run ${reply[1]}');
  return (run: run, launched: reply[0] == 'launched');
}

/// The launch recipe. `run.sh` feeds omp with `tail -f in.jsonl` and pipes its stdout through the pump into
/// `out.jsonl`; it is started in a new session (`setsid`, or Perl's on macOS, which has no `setsid` binary) so neither a
/// terminal hangup nor a Ctrl-C in the launching process group reaches omp, and every descriptor points at
/// run-directory files, so the launching channel can close. `umask 077` is for the run directory only:
/// `run.sh` starts with the launching shell's umask, so the files omp and its tools create get the same
/// permissions as under an attached omp. [loginPath] is the login shell's PATH ([HostProbe.loginPath]): it
/// goes in front of omp's own PATH, and only there — the wrapper's `tail`, `ps` and `mkdir` keep resolving
/// through the PATH sshd gave this script. The reply is `launched <id>` or `found <id>`, then that run's listing
/// (`runs`), so opening a run reads no other run directory.
String posixLaunchScript(String marker, String root, String id, RunSpec spec, {String? loginPath}) {
  final dir = '$root/$id';
  final args = spec.ompArgs('$dir/overlay.yml');
  final meta = RunMeta(
    id: id,
    cwd: spec.cwd,
    omp: spec.omp,
    ompVersion: spec.ompVersion,
    args: args,
    created: DateTime.now(),
    sessionPath: spec.sessionPath,
    companion: spec.companion,
  );
  final session = spec.sessionPath == null ? '' : '"sessionPath":${jsonEncode(spec.sessionPath)},';
  final overlay = spec.overlay.endsWith('\n') ? spec.overlay : '${spec.overlay}\n';
  final runsh = posixRunScript(
    dir,
    spec.omp,
    args,
    tools: spec.tools,
    limits: spec.limits,
    loginPath: loginPath,
    idleExit: spec.idleExit,
  );
  return '''
m=${shQuote(marker)}; R=${shQuote(root)}; D=${shQuote(dir)}; cwd=${shQuote(spec.cwd)}; session=${shQuote(session)}
overlay=${shQuote(overlay)}
meta=${shQuote(jsonEncode(meta.toJson()))}
runsh=${shQuote(runsh)}
$posixLockFunctions$_processFunctions$_runsFunction$_launchBody''';
}

/// `run.sh`: the pipeline's right side runs omp, records its exit code in `code`, and pipes its stdout through the
/// pump ([logScript], the only writer of `out.jsonl` while omp runs); then it records the exit code in `exit` and, as
/// the last line, in `out.jsonl`. The feeding `tail` would only notice omp's death at its next write, so that side kills
/// it too. (`wait $!` cannot be used: bash and dash wait for the whole background pipeline.) [loginPath], the login
/// shell's PATH, reaches omp as `$1` of the inner `sh -c` and is prepended there: the pipeline's own commands keep the
/// PATH sshd gave `run.sh`. With [idleExit], omp gets the run directory and the idle time in its environment.
/// `BUN_BE_BUN` reaches the pump alone. Both inner shells get the path that identifies their process (`in.jsonl`,
/// `overlay.yml`) as an argument, so a command line names it as soon as the pid file exists, before `exec`.
String posixRunScript(
  String dir,
  String omp,
  List<String> args, {
  required AttachTools tools,
  required LogLimits limits,
  String? loginPath,
  Duration? idleExit,
}) {
  final idle = idleExit == null ? '' : 'OMPANION_RUN="\$d" OMPANION_IDLE_EXIT_MS=${idleExit.inMilliseconds} ';
  final pump = [tools.omp, tools.log, 'pump'].map(shQuote).join(' ');
  return '''
d=${shQuote(dir)}
$_processFunctions
$posixTailPoll
sh -c 'echo \$\$ > "\$0/tail.pid"; exec tail \$1 -c +1 -f "\$2"' "\$d" "\$tailpoll" "\$d/in.jsonl" 2>/dev/null | {
  { ${idle}sh -c '$_ompExecBody' "\$d" ${shQuote(loginPath ?? '')} ${[omp, ...args].map(shQuote).join(' ')} 2>> "\$d/err.log"; echo \$? > "\$d/code"; } |
    BUN_BE_BUN=1 $pump "\$d" ${pumpArguments(limits)} 2>> "\$d/err.log"
$_runTail}
''';
}

/// The pump's arguments after the run directory: [LogLimits] as `log.js pump` takes them.
String pumpArguments(LogLimits limits) =>
    '${limits.rotateAt} ${limits.carry} ${limits.hold.inMilliseconds} ${limits.markEvery}';

/// The command the pipeline's right side runs omp with, after `$0` (the run directory) and `$1` (the login
/// shell's PATH, empty when the probe read none): omp's pid goes into `omp.pid` first, so the pid file names
/// the process `exec` leaves behind.
const _ompExecBody =
    r'''echo $$ > "$0/omp.pid"; if [ -n "$1" ]; then PATH="$1:$PATH"; export PATH; fi; shift; exec "$@"''';

const _runTail = r'''
  code=$(cat "$d/code" 2>/dev/null); code=${code:--1}
  i=0
  while [ ! -s "$d/tail.pid" ] && [ $i -lt 100 ]; do sleep 0.01 2>/dev/null || sleep 1; i=$((i + 1)); done
  t=$(cat "$d/tail.pid" 2>/dev/null)
  if running "$t" "$d/in.jsonl"; then kill "$t"; fi
  printf '\n{"type":"ompanion_exit","code":%d}\n' "$code" >> "$d/out.jsonl"
  printf '%d\n' "$code" > "$d/exit.tmp" && mv -f "$d/exit.tmp" "$d/exit"
''';

const _launchBody = r'''
u=$(umask)
umask 077
mkdir -p "$R" || exit 1
chmod 700 "${R%/*}" "$R"
cd "$cwd" || { echo "cannot enter $cwd" >&2; exit 1; }
lock "$R/.launch.lock" 60 || exit 1
trap 'rmdir "$R/.launch.lock" 2>/dev/null' EXIT
if [ -n "$session" ]; then
  for x in "$R"/*; do
    [ -f "$x/meta.json" ] || continue
    grep -qF "$session" "$x/meta.json" || continue
    if running "$(cat "$x/omp.pid" 2>/dev/null)" "$x/overlay.yml" && running "$(cat "$x/tail.pid" 2>/dev/null)" "$x/in.jsonl"; then
      printf '%s:begin\nfound %s\n' "$m" "${x##*/}"
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
printf '%s:begin\nlaunched %s\n' "$m" "${D##*/}"
runs "$D"
printf '%s:end\n' "$m"
''';

Future<List<DetachedRun>> _listPosixRuns(HostLink link, String root) async {
  final marker = newMarker();
  final result = await runPosixScript(link, 'm=${shQuote(marker)}; R=${shQuote(root)}\n$_runsFunction$_listBody');
  if (result.exit.code != 0) throw result.failure('listing runs failed');
  return parsePosixRunList(result.payload(marker), root);
}

const _listBody = r'''
printf '%s:begin\n' "$m"
runs "$R"/*
printf '%s:end\n' "$m"
''';

/// Parses the POSIX run listing (`runs`): two lines per run, `run<TAB>id<TAB>omp pid<TAB>feeder pid<TAB>exit code` and
/// the first line of its `meta.json`; then a `files` line and `<size> <mtime> <path>` per log; then a `procs` line and
/// `<pid> <command line>` per live pid. omp runs while its pid's command line names the run's `overlay.yml`, the
/// feeder while its pid's names the run's `in.jsonl`; a recycled pid names neither.
List<DetachedRun> parsePosixRunList(String payload, String root) {
  final lines = const LineSplitter().convert(payload);
  var i = 0;
  final rows = <(List<String>, String)>[];
  for (; i < lines.length && lines[i] != 'files'; i += 2) {
    final fields = lines[i].split('\t');
    if (fields.length != 5 || fields.first != 'run' || i + 1 == lines.length) {
      throw FormatException('run list: bad line "${lines[i]}"');
    }
    rows.add((fields, lines[i + 1]));
  }
  if (i == lines.length) throw const FormatException('run list: no files section');
  final files = <String, ({int size, int mtime})>{};
  for (i++; i < lines.length && lines[i] != 'procs'; i++) {
    final match = RegExp(r'^(\d+) (\d+) (.+)$').firstMatch(lines[i]);
    if (match == null) throw FormatException('run list: bad file line "${lines[i]}"');
    files[match[3]!] = (size: int.parse(match[1]!), mtime: int.parse(match[2]!));
  }
  if (i == lines.length) throw const FormatException('run list: no procs section');
  final commands = <int, String>{};
  int? last;
  for (i++; i < lines.length; i++) {
    final match = RegExp(r'^\s*(\d+) ?(.*)$').firstMatch(lines[i]);
    if (match != null) {
      commands[last = int.parse(match[1]!)] = match[2]!;
    } else if (last != null) {
      // An argument holding a newline continues the previous command line.
      commands[last] = '${commands[last]}\n${lines[i]}';
    } else {
      throw FormatException('run list: bad process line "${lines[i]}"');
    }
  }
  bool names(String pid, String path) => commands[int.tryParse(pid)]?.contains(path) ?? false;
  final runs = <DetachedRun>[];
  for (final (fields, meta) in rows) {
    final dir = '$root/${fields[1]}';
    final exitCode = int.tryParse(fields[4]);
    final out = files['$dir/out.jsonl'];
    runs.add(
      DetachedRun(
        id: fields[1],
        dir: dir,
        state: switch ((names(fields[2], '$dir/overlay.yml'), names(fields[3], '$dir/in.jsonl'))) {
          (true, true) => RunState.running,
          (true, false) => RunState.stopping,
          (false, _) => exitCode != null ? RunState.exited : RunState.dead,
        },
        meta: parseRunMeta(meta),
        ompPid: int.tryParse(fields[2]),
        exitCode: exitCode,
        outSize: out?.size ?? 0,
        inSize: files['$dir/in.jsonl']?.size ?? 0,
        lastWrite: out == null ? null : DateTime.fromMillisecondsSinceEpoch(out.mtime * 1000, isUtc: true),
      ),
    );
  }
  runs.sort((a, b) => a.id.compareTo(b.id));
  return runs;
}

/// A run's `meta.json` text; null when it is missing or was cut short by a launch that died.
RunMeta? parseRunMeta(String? text) {
  if (text == null || text.trim().isEmpty) return null;
  try {
    return RunMeta.fromJson(asJsonObject(jsonDecode(text), 'meta.json'));
  } on FormatException {
    return null;
  }
}

/// [signal] (`TERM`, `KILL`) is sent to omp; without one, omp's stdin is closed.
Future<int?> _stopPosixRun(HostLink link, DetachedRun run, {required String? signal, required Duration timeout}) async {
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    'm=${shQuote(marker)}; d=${shQuote(run.dir)}; signal=${signal ?? ''}; ticks=${timeout.inMilliseconds ~/ 50}\n'
    '$posixLockFunctions$_processFunctions$_stopBody',
  );
  if (result.exit.code != 0) throw result.failure('stopping run ${run.id} failed');
  final reply = result.payload(marker).trim().split(' ');
  if (reply.first == 'running') throw HostLinkException('omp of run ${run.id} still runs after $timeout');
  return reply.length > 1 ? int.tryParse(reply[1]) : null;
}

/// Waits for the `exit` file; gives up early once omp has been gone for a second without one being written.
const _stopBody = r'''
p=$(cat "$d/omp.pid" 2>/dev/null)
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
''';

Future<List<String>> _removePosixRuns(HostLink link, String root, List<String> ids) async {
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    'm=${shQuote(marker)}; R=${shQuote(root)}\nset -- ${ids.map(shQuote).join(' ')}\n'
    '$posixLockFunctions$_processFunctions$_removeBody',
  );
  if (result.exit.code != 0) throw result.failure('removing runs failed');
  return const LineSplitter().convert(result.payload(marker)).where((l) => l.isNotEmpty).toList();
}

/// Holds the launch lock, so no device launches into or finds a directory being removed, and re-checks
/// liveness under it. A feeder left behind by a killed wrapper is stopped first.
const _removeBody = r'''
lock "$R/.launch.lock" 60 || exit 1
trap 'rmdir "$R/.launch.lock" 2>/dev/null' EXIT
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
''';

/// Under the launch lock, so a launch looking for the session sees the old record or the new one.
const _recordBody = r'''
lock "$R/.launch.lock" 60 || exit 1
trap 'rmdir "$R/.launch.lock" 2>/dev/null' EXIT
r=same
if ! grep -qF "$session" "$d/meta.json"; then
  printf '%s\n' "$meta" > "$d/meta.json.tmp" && mv -f "$d/meta.json.tmp" "$d/meta.json" || exit 1
  r=updated
fi
printf '%s:begin\n%s\n%s:end\n' "$m" "$r" "$m"
''';
