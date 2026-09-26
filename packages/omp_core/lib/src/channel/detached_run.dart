import 'dart:convert';
import 'dart:math';

import '../host/probe.dart';
import '../host/scripts.dart';
import '../rpc/json_fields.dart';
import '../transport/host_link.dart';
import 'detached_channel.dart';
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
    this.sessionPath,
    this.companion,
    this.overlay = defaultOverlay,
    this.args = const [],
  });

  /// Absolute path of the omp binary (the probed one).
  final String omp;
  final String ompVersion;
  final String cwd;

  /// `--session`; null starts a new session.
  final String? sessionPath;

  /// `-e`: the companion extension.
  final String? companion;

  /// YAML written to the run's `overlay.yml` and passed with `--config`.
  final String overlay;

  /// Further omp arguments, e.g. `['--model', 'fake/fake-1']`.
  final List<String> args;

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
    required this.generation,
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
    generation: json.integer('generation'),
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

  /// `out.jsonl` generation, raised by each rotation.
  final int generation;
  final DateTime created;

  /// The session the run was launched with; null for a run that started a new session.
  final String? sessionPath;
  final String? companion;

  /// Key order and compact encoding are fixed: host scripts match `"sessionPath":<value>,` and
  /// `"generation":<n>` textually.
  Map<String, Object?> toJson() => {
    'id': id,
    'sessionPath': sessionPath,
    'cwd': cwd,
    'omp': omp,
    'ompVersion': ompVersion,
    'companion': companion,
    'args': args,
    'generation': generation,
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

/// Attaches to [run]. `out.jsonl` is read from [offset] when [generation] is still the run's generation,
/// otherwise from the start of the current generation; `in.jsonl` from [inboxOffset], or from its current
/// end when null.
Future<RunChannel> attachRun(
  HostLink link,
  HostProbe probe,
  DetachedRun run, {
  int? generation,
  int offset = 0,
  int? inboxOffset,
}) => probe.isWindows
    ? attachWindowsRun(link, probe, run, generation: generation, offset: offset, inboxOffset: inboxOffset)
    : DetachedChannel.attach(link, run.dir, generation: generation, offset: offset, inboxOffset: inboxOffset);

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
    : _stopPosixRun(link, run, force: force, timeout: timeout);

/// Removes the directories of runs that are not live and whose `out.jsonl` was last written more than
/// [olderThan] ago. Returns the removed run ids.
Future<List<String>> removeDeadRuns(HostLink link, HostProbe probe, {Duration olderThan = Duration.zero}) async {
  final now = DateTime.now();
  final dead = [
    for (final run in await listRuns(link, probe))
      if (!run.live && (run.lastWrite == null || now.difference(run.lastWrite!) >= olderThan)) run.id,
  ];
  if (dead.isEmpty) return const [];
  return probe.isWindows ? removeWindowsRuns(link, probe, dead) : _removePosixRuns(link, runRoot(probe), dead);
}

/// Truncates `out.jsonl` and starts the next generation, holding the append lock so no command arrives
/// meanwhile. Call it only while the session is settled: output omp writes during the rotation lands in the
/// new generation ahead of its first line. Attached channels continue seamlessly when they had read
/// everything, otherwise their `lines` fail with [RunLogGap]. POSIX only: cmd.exe's `>>` keeps writing at
/// its old offset after a truncation. [settledAt] is where the caller read a `session_settled`: the log is rotated
/// only while it is still that generation and size, so nothing was written since and no other device rotated first.
/// Returns the new generation, or the current one when the log was left alone.
Future<int> rotateRunOutput(
  HostLink link,
  HostProbe probe,
  DetachedRun run, {
  ({int generation, int size})? settledAt,
}) async {
  if (probe.isWindows) throw UnsupportedError('out.jsonl is not rotated on Windows hosts');
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    'm=${shQuote(marker)}; d=${shQuote(run.dir)}; g0=${settledAt?.generation ?? -1}; s0=${settledAt?.size ?? -1}\n'
    '$posixLockFunctions$_processFunctions$_rotateBody',
  );
  if (result.exit.code != 0) throw result.failure('rotating ${run.dir}/out.jsonl failed');
  return int.parse(result.payload(marker).trim().split(' ').first);
}

/// Records [sessionPath] as the session [run] holds in its `meta.json`, so a device opening that session finds this
/// run instead of launching a second omp. omp changes files inside a run (`new_session`, `switch_session`,
/// `branch`, fork), and a run launched without `--session` learns its file from `get_state`. Holds the launch lock,
/// so a launch looking for the session sees either record, and on POSIX the append lock, so a rotation's own
/// rewrite of `meta.json` cannot interleave. Returns whether `meta.json` changed.
Future<bool> recordRunSession(HostLink link, HostProbe probe, DetachedRun run, String sessionPath) async {
  final meta = run.meta;
  if (meta == null) throw HostLinkException('run ${run.id} has no readable meta.json');
  if (probe.isWindows) return _recordWindowsRunSession(link, probe, run, sessionPath);
  final generation = '"generation":${meta.generation}';
  final text = jsonEncode(_withSession(meta, sessionPath).toJson());
  // String values escape every `"`, so the key occurs once; the script puts the current generation between the halves.
  final at = text.indexOf('$generation,');
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    'm=${shQuote(marker)}; R=${shQuote(runRoot(probe))}; d=${shQuote(run.dir)}\n'
    'session=${shQuote('"sessionPath":${jsonEncode(sessionPath)},')}\n'
    'head=${shQuote(text.substring(0, at + '"generation":'.length))}; tail=${shQuote(text.substring(at + generation.length))}\n'
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
  generation: meta.generation,
  created: meta.created,
  sessionPath: sessionPath,
  companion: meta.companion,
);

/// Windows runs are never rotated, so `meta.json` is rewritten whole, under the SFTP launch lock.
Future<bool> _recordWindowsRunSession(HostLink link, HostProbe probe, DetachedRun run, String sessionPath) async {
  final files = await link.files();
  try {
    final lock = toSftpPath('${runRoot(probe)}\\.launch.lock');
    await acquireDirLock(files, lock, timeout: const Duration(seconds: 60), stale: const Duration(seconds: 60));
    try {
      final path = '${toSftpPath(run.dir)}/meta.json';
      final meta = parseRunMeta(utf8.decode(await files.read(path), allowMalformed: true));
      if (meta == null) throw HostLinkException('run ${run.id} has no readable meta.json');
      if (meta.sessionPath == sessionPath) return false;
      final temp = '$path.${newMarker()}.tmp';
      await files.write(temp, utf8.encode('${jsonEncode(_withSession(meta, sessionPath).toJson())}\n'));
      await files.remove(path);
      await files.rename(temp, path);
      return true;
    } finally {
      await files.removeDir(lock);
    }
  } finally {
    await files.close();
  }
}

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
size() { if [ -f "$1" ]; then wc -c < "$1" | tr -d ' '; else echo 0; fi; }
''';

Future<({DetachedRun run, bool launched})> _openPosixRun(HostLink link, HostProbe probe, RunSpec spec) async {
  final marker = newMarker();
  final root = runRoot(probe);
  final result = await runPosixScript(link, posixLaunchScript(marker, root, newRunId(), spec));
  if (result.exit.code != 0) throw result.failure('launching omp in ${spec.cwd} failed');
  final reply = result.payload(marker).trim().split(' ');
  if (reply.length != 2) throw result.failure('unexpected launch reply "${reply.join(' ')}"');
  final run = (await _listPosixRuns(link, root)).where((r) => r.id == reply[1]).firstOrNull;
  if (run == null) throw HostLinkException('run ${reply[1]} vanished right after the launch');
  return (run: run, launched: reply[0] == 'launched');
}

/// The launch recipe. `run.sh` feeds omp with `tail -f in.jsonl` and appends its stdout to `out.jsonl`; it is
/// started in a new session (`setsid`, or Perl's on macOS, which has no `setsid` binary) so neither a
/// terminal hangup nor a Ctrl-C in the launching process group reaches omp, and every descriptor points at
/// run-directory files, so the launching channel can close. `umask 077` is for the run directory only:
/// `run.sh` starts with the launching shell's umask, so the files omp and its tools create get the same
/// permissions as under an attached omp.
String posixLaunchScript(String marker, String root, String id, RunSpec spec) {
  final dir = '$root/$id';
  final args = spec.ompArgs('$dir/overlay.yml');
  final meta = RunMeta(
    id: id,
    cwd: spec.cwd,
    omp: spec.omp,
    ompVersion: spec.ompVersion,
    args: args,
    generation: 1,
    created: DateTime.now(),
    sessionPath: spec.sessionPath,
    companion: spec.companion,
  );
  final session = spec.sessionPath == null ? '' : '"sessionPath":${jsonEncode(spec.sessionPath)},';
  final overlay = spec.overlay.endsWith('\n') ? spec.overlay : '${spec.overlay}\n';
  return '''
m=${shQuote(marker)}; R=${shQuote(root)}; D=${shQuote(dir)}; cwd=${shQuote(spec.cwd)}; session=${shQuote(session)}
overlay=${shQuote(overlay)}
meta=${shQuote(jsonEncode(meta.toJson()))}
runsh=${shQuote(posixRunScript(dir, spec.omp, args))}
$posixLockFunctions$_processFunctions$_launchBody''';
}

/// `run.sh`: the pipeline's right side runs omp in the foreground, then records its exit code in `exit` and,
/// as the last line, in `out.jsonl`. The feeding `tail` would only notice omp's death at its next write, so
/// that side kills it too. (`wait $!` cannot be used: bash and dash wait for the whole background pipeline.)
String posixRunScript(String dir, String omp, List<String> args) =>
    '''
d=${shQuote(dir)}
$_processFunctions
$posixTailPoll
sh -c 'echo \$\$ > "\$0/tail.pid"; exec tail \$1 -c +1 -f "\$0/in.jsonl"' "\$d" "\$tailpoll" 2>/dev/null | {
  sh -c 'echo \$\$ > "\$0/omp.pid"; exec "\$@"' "\$d" ${[omp, ...args].map(shQuote).join(' ')} >> "\$d/out.jsonl" 2>> "\$d/err.log"
$_runTail}
''';

const _runTail = r'''
  code=$?
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
      printf '%s:begin\nfound %s\n%s:end\n' "$m" "${x##*/}" "$m"
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
printf '%s:begin\nlaunched %s\n%s:end\n' "$m" "${D##*/}" "$m"
''';

Future<List<DetachedRun>> _listPosixRuns(HostLink link, String root) async {
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    'm=${shQuote(marker)}; R=${shQuote(root)}\n$posixLockFunctions$_processFunctions$_listBody',
  );
  if (result.exit.code != 0) throw result.failure('listing runs failed');
  return parsePosixRunList(result.payload(marker), root);
}

const _listBody = r'''
printf '%s:begin\n' "$m"
for d in "$R"/*; do
  [ -d "$d" ] || continue
  p=$(cat "$d/omp.pid" 2>/dev/null)
  a=0; if running "$p" "$d/overlay.yml"; then a=1; fi
  f=0; if running "$(cat "$d/tail.pid" 2>/dev/null)" "$d/in.jsonl"; then f=1; fi
  e=$(cat "$d/exit" 2>/dev/null)
  printf 'run\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${d##*/}" "$p" "$a" "$f" "$e" \
    "$(size "$d/out.jsonl")" "$(size "$d/in.jsonl")" "$(mtime "$d/out.jsonl")"
  printf '%s\n' "$(head -n 1 "$d/meta.json" 2>/dev/null)"
done
printf '%s:end\n' "$m"
''';

/// Parses the payload of the POSIX run listing: two lines per run, its fields and its `meta.json`.
List<DetachedRun> parsePosixRunList(String payload, String root) {
  final lines = const LineSplitter().convert(payload);
  final runs = <DetachedRun>[];
  for (var i = 0; i + 1 < lines.length; i += 2) {
    final fields = lines[i].split('\t');
    if (fields.length != 9 || fields.first != 'run') throw FormatException('run list: bad line "${lines[i]}"');
    final exitCode = int.tryParse(fields[5]);
    final written = int.tryParse(fields[8]);
    runs.add(
      DetachedRun(
        id: fields[1],
        dir: '$root/${fields[1]}',
        state: switch ((fields[3] == '1', fields[4] == '1')) {
          (true, true) => RunState.running,
          (true, false) => RunState.stopping,
          (false, _) => exitCode != null ? RunState.exited : RunState.dead,
        },
        meta: parseRunMeta(lines[i + 1]),
        ompPid: int.tryParse(fields[2]),
        exitCode: exitCode,
        outSize: int.tryParse(fields[6]) ?? 0,
        inSize: int.tryParse(fields[7]) ?? 0,
        lastWrite: written == null ? null : DateTime.fromMillisecondsSinceEpoch(written * 1000, isUtc: true),
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

Future<int?> _stopPosixRun(HostLink link, DetachedRun run, {required bool force, required Duration timeout}) async {
  final marker = newMarker();
  final result = await runPosixScript(
    link,
    'm=${shQuote(marker)}; d=${shQuote(run.dir)}; force=${force ? 1 : 0}; ticks=${timeout.inMilliseconds ~/ 50}\n'
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
if [ "$force" = 1 ]; then
  if running "$p" "$d/overlay.yml"; then kill -TERM "$p"; fi
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

const _rotateBody = r'''
lock "$d/in.lock" 30 || exit 1
trap 'rmdir "$d/in.lock" 2>/dev/null' EXIT
g=$(sed -n 's/.*"generation":\([0-9][0-9]*\).*/\1/p' "$d/meta.json")
if [ -z "$g" ]; then echo "no generation in $d/meta.json" >&2; exit 1; fi
s=$(size "$d/out.jsonl")
if { [ "$g0" -ge 0 ] && [ "$g" != "$g0" ]; } || { [ "$s0" -ge 0 ] && [ "$s" != "$s0" ]; }; then
  printf '%s:begin\n%s %s\n%s:end\n' "$m" "$g" "$s" "$m"; exit 0
fi
n=$((g + 1))
sed "s/\"generation\":$g/\"generation\":$n/" "$d/meta.json" > "$d/meta.json.tmp" && mv -f "$d/meta.json.tmp" "$d/meta.json" || exit 1
: > "$d/out.jsonl"
printf '{"type":"ompanion_rotate","generation":%d,"previousSize":%d}\n' "$n" "$s" >> "$d/out.jsonl"
printf '%s:begin\n%s %s\n%s:end\n' "$m" "$n" "$s" "$m"
''';

/// Lock order: launch lock, then append lock (rotation takes only the latter, launches only the former).
const _recordBody = r'''
lock "$R/.launch.lock" 60 || exit 1
trap 'rmdir "$R/.launch.lock" 2>/dev/null' EXIT
lock "$d/in.lock" 30 || exit 1
trap 'rmdir "$d/in.lock" 2>/dev/null; rmdir "$R/.launch.lock" 2>/dev/null' EXIT
r=same
if ! grep -qF "$session" "$d/meta.json"; then
  g=$(sed -n 's/.*"generation":\([0-9][0-9]*\).*/\1/p' "$d/meta.json")
  if [ -z "$g" ]; then echo "no generation in $d/meta.json" >&2; exit 1; fi
  printf '%s%s%s\n' "$head" "$g" "$tail" > "$d/meta.json.tmp" && mv -f "$d/meta.json.tmp" "$d/meta.json" || exit 1
  r=updated
fi
printf '%s:begin\n%s\n%s:end\n' "$m" "$r" "$m"
''';
