import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../channel/attached_channel.dart';
import '../channel/detached_run.dart' hide listRuns;
import '../channel/detached_run.dart' as runs show listRuns;
import '../channel/follow.dart';
import '../channel/run_log.dart';
import '../host/companion.dart';
import '../host/host_image.dart';
import '../host/probe.dart';
import '../host/scripts.dart';
import '../host/session_listing.dart' hide listSessions;
import '../host/session_listing.dart' as listing show listSessions;
import '../host/session_writer.dart';
import '../transport/host_link.dart';
import 'external_session.dart';
import 'live_session.dart';
import 'run_session.dart';

/// How long a run sits idle before its companion ends omp (docs/contracts/host-launch.md, "Idle exit"). Coming back
/// then costs a cold open instead of an attach: 1.8–3.7 s against 0.2–0.3 s for a 400 MB session over SSH
/// (docs/research/ui-libraries.md), so a session left for a short break stays attachable.
const defaultIdleExit = Duration(hours: 1);

/// How long the directory of a run whose omp ended stays on the machine: its `err.log` explains a crash.
const deadRunLifetime = Duration(days: 3);

/// The model of a bootstrap control process (`MachineRuntime.controlIsBootstrap`). omp's bundled catalog has it, and
/// its provider has no model manager (`MODEL_MANAGER_FACTORIES` in `catalog/src/provider-models/descriptors.ts`), so
/// `--model` resolves it offline and omp never runs discovery against minimax. It is a plain API-key provider, so
/// `--api-key` makes it usable without touching stored credentials.
const bootstrapModel = 'minimax/MiniMax-M2';

/// Connection state of one machine.
sealed class MachineStatus {
  const MachineStatus();
}

final class MachineOffline extends MachineStatus {
  const MachineOffline();
}

final class MachineConnecting extends MachineStatus {
  const MachineConnecting();
}

/// Connected, probed, omp [minimumOmpVersion] or newer found and the companion uploaded.
final class MachineOnline extends MachineStatus {
  const MachineOnline(this.probe);

  final HostProbe probe;
}

/// Connecting or probing failed.
final class MachineFailed extends MachineStatus {
  const MachineFailed(this.cause);

  final Object cause;
}

/// Connected, but omp is missing or older than [minimumOmpVersion]: offer the install. The link works.
final class MachineNeedsOmp extends MachineStatus {
  const MachineNeedsOmp(this.probe, this.reason);

  final HostProbe probe;
  final String reason;
}

/// What `MachineRuntime.open` opens.
sealed class SessionOpen {
  const SessionOpen();
}

/// A new session in [cwd] (host-native path). [model] (`provider/id`) and [thinkingLevel] become omp's `--model`
/// and `--thinking`; without them omp uses its configured defaults. omp names the session file; the run records
/// it at the first attach.
final class NewSession extends SessionOpen {
  const NewSession(this.cwd, {this.model, this.thinkingLevel});

  final String cwd;
  final String? model;
  final String? thinkingLevel;
}

/// The session in file [sessionPath]: attaches to the live run holding it, or launches one in the session's
/// directory (the home directory when that is gone).
final class ResumeSession extends SessionOpen {
  const ResumeSession(this.sessionPath);

  final String sessionPath;
}

/// The live run [runId] (`DetachedRun.id`). Throws [RunEnded] for a run whose omp exited: resume its session
/// instead.
final class AttachRun extends SessionOpen {
  const AttachRun(this.runId);

  final String runId;
}

/// A local TCP port forwarded to a port on the machine's loopback.
abstract interface class LocalForward {
  int get localPort;
  int get remotePort;

  /// Stops listening and closes every forwarded connection.
  Future<void> close();
}

typedef _Connection = ({
  HostLink link,
  HostProbe probe,
  ({String companion, String log, String follow})? uploaded,
  String? problem,
});

typedef _Ready = ({HostLink link, HostProbe probe, String companion, AttachTools tools});

/// Everything the app does with one machine: the connection, the probe, the companion upload, the session list and
/// the open sessions. Sessions share one link; after it drops, each reconnects through [connect].
final class MachineRuntime {
  /// [connect] opens a fresh link; it is called again after the link dropped. [deviceId] is stable per app install
  /// and namespaces RPC ids. [companionBytes] supplies the companion build for an omp version. [overlay] holds
  /// config keys (dotted paths, values written as YAML) for every run's `--config` overlay, which always forces
  /// `speech.enabled: false`. [searchSystemPaths] false keeps the probe to omp in the machine's home directory
  /// ([probeHost]), for a machine whose home is an isolated one. Every run this runtime launches ends its omp after
  /// [idleExit] without activity.
  MachineRuntime({
    required this._connect,
    required this.deviceId,
    required this._companionBytes,
    Map<String, String> overlay = const {},
    this._searchSystemPaths = true,
    this.idleExit = defaultIdleExit,
  }) : _overlay = renderOverlay(overlay);

  final Future<HostLink> Function() _connect;
  final Future<List<int>> Function(String ompVersion) _companionBytes;
  final String _overlay;
  final bool _searchSystemPaths;
  final String deviceId;
  final Duration idleExit;

  final _statuses = StreamController<MachineStatus>.broadcast();
  MachineStatus _status = const MachineOffline();
  _Connection? _connection;
  Future<_Connection>? _connecting;
  Future<_Connection>? _reprobing;

  /// Open sessions by run id, including ones still attaching.
  final _opens = <String, Future<RunSession>>{};
  final _sessions = <RunSession>{};

  /// Readers of session files another process holds ([ExternalSession]), by session file path, while they are open.
  final _external = <String, ExternalSession>{};
  RunSession? _control;
  _ControlAccess? _controlAccess;
  Future<RunSession>? _controlStarting;
  final _forwards = <_Forward>{};
  ({HostLink link, Future<ImageTools> tools})? _imageTools;
  bool _disposed = false;

  /// Emits every new [status]. Broadcast.
  Stream<MachineStatus> get statuses => _statuses.stream;

  MachineStatus get status => _status;

  /// The current link. Throws [StateError] while the machine is not connected.
  HostLink get link => _connection?.link ?? (throw StateError('not connected; call connectAndProbe() first'));

  /// Connects unless connected, probes once per connection, and uploads the companion for the probed omp. Returns
  /// the probe; [status] is [MachineNeedsOmp] when omp is missing or too old, and the link stays usable. Throws
  /// when connecting or probing fails ([MachineFailed]). After omp was installed or replaced, [reprobe] sees it.
  Future<HostProbe> connectAndProbe() async => (await _connected()).probe;

  /// Probes the connected machine again and uploads the companion for the omp found now, e.g. after installing omp;
  /// connects first when not connected, as [connectAndProbe] does. [status] follows the new probe. A failed probe
  /// throws and leaves the connection and [status] as they were. Calls made while one runs share it.
  Future<HostProbe> reprobe() async {
    if (_connection == null && _connecting == null) return connectAndProbe();
    return (await (_reprobing ??= _reprobe().whenComplete(() => _reprobing = null))).probe;
  }

  /// Session files on the machine, newest first, each with the live run holding it. Sessions of live runs that omp
  /// has not written yet (no message so far) are included. Directories of runs that ended more than
  /// [deadRunLifetime] ago are removed on the way.
  Future<List<SessionSummary>> listSessions() async {
    final connection = await _connected();
    final results = await Future.wait<Object>([
      listing.listSessions(connection.link, connection.probe),
      runs.listRuns(connection.link, connection.probe),
    ]);
    final sessions = results[0] as List<SessionSummary>;
    final runList = results[1] as List<DetachedRun>;
    await removeDeadRuns(connection.link, connection.probe, olderThan: deadRunLifetime, runs: runList);
    final live = <String, DetachedRun>{
      for (final run in runList)
        if (run.state == RunState.running && run.meta?.sessionPath != null) run.meta!.sessionPath!: run,
    };
    return [
      for (final session in sessions)
        if (live.remove(session.path) case final run?) session.withRun(run.id) else session,
      for (final run in live.values) _unwrittenSession(run),
    ]..sort((a, b) => b.modified.compareTo(a.modified));
  }

  /// Every run directory on the machine, oldest first.
  Future<List<DetachedRun>> listRuns() async {
    final connection = await _connected();
    return runs.listRuns(connection.link, connection.probe);
  }

  /// ffmpeg on the machine ([probeImageTools]), looked up once per connection. A failed lookup is tried again on the
  /// next call.
  Future<ImageTools> imageTools() async {
    final connection = await _connected();
    final cached = _imageTools;
    if (cached != null && identical(cached.link, connection.link)) return cached.tools;
    final tools = probeImageTools(connection.link, connection.probe);
    _imageTools = (link: connection.link, tools: tools);
    try {
      return await tools;
    } on Object {
      if (identical(_imageTools?.tools, tools)) _imageTools = null;
      rethrow;
    }
  }

  /// Opens a session: launches or finds its run, attaches, and completes once the view is built. An open session
  /// is returned again for the same run or session file. Throws [OmpUnavailable] when omp is missing or too old,
  /// [OmpStartFailed] when omp exits before it is ready, [RunEnded], [RunGone], or the transport's error.
  Future<LiveSession> open(SessionOpen request) async {
    final ready = await _ready();
    switch (request) {
      case AttachRun(:final runId):
        if (_opens[runId] case final open?) return open;
        final run = (await runs.listRuns(ready.link, ready.probe)).where((run) => run.id == runId).firstOrNull;
        if (run == null) throw RunGone('no run $runId on ${ready.link.label}');
        if (!run.live) throw RunEnded(runId, run.exitCode);
        return _openRun(run, ready.probe);
      case ResumeSession(:final sessionPath):
        for (final session in _sessions) {
          // The open's future: completes once a session still attaching is ready.
          if (session.sessionPath == sessionPath) return _opens[session.runId] ?? session;
        }
        final live = (await runs.listRuns(
          ready.link,
          ready.probe,
        )).where((run) => run.state == RunState.running && run.meta?.sessionPath == sessionPath).firstOrNull;
        // Probed before the run is attached: a process that holds the file wins over the app's run even before it
        // writes. The run's own omp holds the file too once it appended, and is left out.
        final writer = await probeSessionWriter(ready.link, ready.probe, sessionPath, runPid: live?.ompPid);
        if (live != null) {
          if (writer == null) {
            final attached = await _openRun(live, ready.probe);
            if (!attached.behindFile) return attached;
            await attached.detach();
          }
          // Another process (a terminal omp) holds the file, or wrote it after this run's omp loaded it: the run's
          // history is or will be stale, and a prompt there would fork the session off its old leaf. The omp is
          // killed before it can write its exit record there, and the file is opened as if no run of the app held it.
          await killRun(ready.link, ready.probe, live);
        }
        final cwd = await _sessionCwd(ready.link, ready.probe, sessionPath);
        // A process the app did not start holds the file: launching here would put a second writer on one session
        // file. Read the file instead ([ExternalSession]); it offers the take-over once the writer is gone.
        if (writer != null) {
          if (_external[sessionPath] case final open?) return open;
          final external = ExternalSession(
            sessionPath: sessionPath,
            cwd: cwd,
            link: ready.link,
            probe: ready.probe,
            writer: writer,
          );
          external.onClosed = () {
            if (identical(_external[sessionPath], external)) _external.remove(sessionPath);
          };
          _external[sessionPath] = external;
          await external.start();
          return external;
        }
        // The launch looks for a live run of the session again, under the machine's launch lock.
        final (:run, launched: _) = await openRun(ready.link, ready.probe, _spec(ready, cwd, sessionPath: sessionPath));
        return _openRun(run, ready.probe);
      case NewSession(:final cwd, :final model, :final thinkingLevel):
        final args = [
          if (model != null) ...['--model', model],
          if (thinkingLevel != null) ...['--thinking', thinkingLevel],
        ];
        final (:run, launched: _) = await openRun(ready.link, ready.probe, _spec(ready, cwd, args: args));
        return _openRun(run, ready.probe);
    }
  }

  /// The machine-level `omp --mode rpc-ui --no-session` on the link itself, for settings, roles, accounts, login,
  /// models and session lists: started on first use, restarted after it exits, shared by every caller. Throws like
  /// [open]; [OmpStartFailed.stderr] carries omp's reason.
  ///
  /// On a machine where omp finds no usable model, omp refuses rpc mode; the control then runs in bootstrap mode
  /// ([controlIsBootstrap]) so settings, `accounts.setKey` and `login` still work. Once a key was stored or a login
  /// succeeded there, the next call ends it and starts a normal one. So does a call after [reprobe] found another
  /// omp than the one the control runs (an update), whose models and settings may differ.
  Future<LiveSession> control() {
    final current = _control;
    if (current != null && current.linkState is! LinkClosed) {
      final access = _controlAccess;
      final probe = _connection?.probe;
      final launched = access?.launched;
      final ompChanged =
          probe != null && launched != null && (launched.path, launched.version) != (probe.ompPath, probe.ompVersion);
      if (!(access?.credentialsChanged ?? false) && !ompChanged) return Future.value(current);
      _control = null;
      return _controlStarting ??= current
          .stop()
          .then((_) => _startControl())
          .whenComplete(() => _controlStarting = null);
    }
    return _controlStarting ??= _startControl().whenComplete(() => _controlStarting = null);
  }

  /// True while the control session runs in bootstrap mode: omp found no usable model on the machine, so the control
  /// runs on [bootstrapModel] with a placeholder key and refuses anything that makes a model call. The UI should say
  /// that no model works yet and offer sign-in or an API key.
  bool get controlIsBootstrap => _control != null && (_controlAccess?.bootstrap ?? false);

  /// Listens on 127.0.0.1:[localPort] (0 picks a free port) and forwards each connection to 127.0.0.1:[remotePort]
  /// on the machine, over the link current at that moment.
  Future<LocalForward> forwardLocal(int remotePort, {int localPort = 0}) async {
    await _connected();
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, localPort);
    final forward = _Forward(server, remotePort, () async => (await _connected()).link);
    forward.onClosed = () => _forwards.remove(forward);
    _forwards.add(forward);
    return forward;
  }

  /// Detaches every session (their runs keep going on the machine), ends the control process, closes forwards and
  /// the link.
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      for (final session in _sessions.toList()) session.detach(),
      for (final external in _external.values.toList()) external.detach(),
      if (_control case final control?) control.detach(),
      for (final forward in _forwards.toList()) forward.close(),
    ]);
    final connection = _connection;
    _connection = null;
    await connection?.link.close();
    _setStatus(const MachineOffline());
    await _statuses.close();
  }

  // Connection ------------------------------------------------------------------------------------------------------

  Future<_Connection> _connected() {
    if (_disposed) throw StateError('the machine runtime was disposed');
    final current = _connection;
    if (current != null) return Future.value(current);
    return _connecting ??= _open().whenComplete(() => _connecting = null);
  }

  Future<_Ready> _ready() async {
    final connection = await _connected();
    final uploaded = connection.uploaded;
    if (uploaded == null) throw OmpUnavailable(connection.problem ?? 'omp is not usable on ${connection.link.label}');
    final probe = connection.probe;
    return (
      link: connection.link,
      probe: probe,
      companion: uploaded.companion,
      tools: (omp: probe.ompPath!, log: uploaded.log, follow: uploaded.follow),
    );
  }

  Future<_Connection> _open() async {
    _setStatus(const MachineConnecting());
    final HostLink link;
    try {
      link = await _connect();
    } on Object catch (error) {
      if (!_disposed) _setStatus(MachineFailed(error));
      rethrow;
    }
    try {
      final connection = await _probe(link);
      if (_disposed) throw StateError('the machine runtime was disposed');
      _connection = connection;
      unawaited(link.done.then((_) => _dropped(link)));
      final problem = connection.problem;
      _setStatus(problem == null ? MachineOnline(connection.probe) : MachineNeedsOmp(connection.probe, problem));
      return connection;
    } on Object catch (error) {
      unawaited(link.close());
      if (!_disposed) _setStatus(MachineFailed(error));
      rethrow;
    }
  }

  Future<_Connection> _reprobe() async {
    final current = await _connected();
    final connection = await _probe(current.link);
    if (_disposed) throw StateError('the machine runtime was disposed');
    // The link dropped while probing; the connection that replaces it probes by itself.
    if (!identical(_connection, current)) return _connected();
    _connection = connection;
    final problem = connection.problem;
    _setStatus(problem == null ? MachineOnline(connection.probe) : MachineNeedsOmp(connection.probe, problem));
    return connection;
  }

  /// Probes [link] and uploads the companion and the attach scripts when the app can drive the omp found there.
  Future<_Connection> _probe(HostLink link) async {
    final probe = await probeHost(link, searchSystemPaths: _searchSystemPaths);
    final problem = ompProblem(probe);
    final version = probe.ompVersion;
    final uploaded = problem == null && version != null
        ? await uploadCompanion(link, ompVersion: version, bytes: await _companionBytes(version))
        : null;
    return (link: link, probe: probe, uploaded: uploaded, problem: problem);
  }

  void _dropped(HostLink link) {
    if (!identical(_connection?.link, link)) return;
    _connection = null;
    if (!_disposed) _setStatus(const MachineOffline());
  }

  void _setStatus(MachineStatus status) {
    _status = status;
    if (!_statuses.isClosed) _statuses.add(status);
  }

  // Sessions --------------------------------------------------------------------------------------------------------

  RunSpec _spec(_Ready ready, String cwd, {String? sessionPath, List<String> args = const []}) => RunSpec(
    omp: ready.probe.ompPath!,
    ompVersion: ready.probe.ompVersion!,
    cwd: cwd,
    tools: ready.tools,
    sessionPath: sessionPath,
    companion: ready.companion,
    overlay: _overlay,
    args: args,
    idleExit: idleExit,
  );

  Future<RunSession> _openRun(DetachedRun run, HostProbe probe) => _opens[run.id] ??= _startRun(run, probe);

  Future<RunSession> _startRun(DetachedRun run, HostProbe probe) async {
    final session = RunSession(
      runId: run.id,
      cwd: run.meta?.cwd ?? probe.home,
      access: _DetachedAccess(this, run),
      deviceId: deviceId,
      recordedPath: run.meta?.sessionPath,
    );
    session.onClosed = () {
      _sessions.remove(session);
      _opens.remove(run.id);
    };
    _sessions.add(session);
    await session.start();
    return session;
  }

  /// A normal control process, or on a machine where omp finds no usable model (it refuses rpc mode then), one in
  /// bootstrap mode.
  Future<RunSession> _startControl() async {
    final ready = await _ready();
    try {
      return await _launchControl(ready, bootstrap: false);
    } on OmpStartFailed catch (error) {
      // omp prints this with every variant of its no-model exit (`main.ts`, the `!session.model` check).
      if (!error.stderr.contains('Set an API key environment variable')) rethrow;
    }
    return _launchControl(ready, bootstrap: true);
  }

  Future<RunSession> _launchControl(_Ready ready, {required bool bootstrap}) async {
    final access = _ControlAccess(this, bootstrap: bootstrap);
    final session = RunSession(runId: 'control', cwd: ready.probe.home, access: access, deviceId: deviceId);
    session.onClosed = () {
      if (identical(_control, session)) _control = null;
    };
    await session.start();
    _control = session;
    _controlAccess = access;
    return session;
  }

  /// The session header's `cwd` when that directory still exists, else the home directory.
  static Future<String> _sessionCwd(HostLink link, HostProbe probe, String sessionPath) async {
    final files = await link.files();
    try {
      // The title slot (256 bytes), then the header line.
      final head = utf8.decode(await files.read(toSftpPath(sessionPath), length: 16384), allowMalformed: true);
      for (final line in const LineSplitter().convert(head).take(2)) {
        final Object? json;
        try {
          json = jsonDecode(line);
        } on FormatException {
          // A header longer than the read is cut off; the home directory stands in.
          continue;
        }
        if (json case {'type': 'session', 'cwd': final String cwd}) {
          final stat = await files.stat(toSftpPath(cwd));
          return stat != null && stat.isDirectory ? cwd : probe.home;
        }
      }
      return probe.home;
    } finally {
      await files.close();
    }
  }

  /// A live run's session whose file omp has not written yet; its name carries omp's session id.
  static SessionSummary _unwrittenSession(DetachedRun run) {
    final meta = run.meta!;
    final path = meta.sessionPath!;
    final name = path.split(RegExp(r'[/\\]')).last;
    return SessionSummary(
      path: path,
      size: 0,
      modified: run.lastWrite ?? meta.created,
      id: RegExp(r'_([^_]+)\.jsonl$').firstMatch(name)?.group(1) ?? name,
      cwd: meta.cwd,
      created: meta.created,
      runId: run.id,
    );
  }
}

/// Why omp on the probed machine cannot be driven, or null when it can.
String? ompProblem(HostProbe probe) {
  final path = probe.ompPath;
  final version = probe.ompVersion;
  if (path == null) return 'omp is not installed';
  if (version == null) return 'omp at $path did not report its version';
  if (compareOmpVersions(version, minimumOmpVersion) < 0) return 'omp $version is older than $minimumOmpVersion';
  return null;
}

/// The `--config` overlay of every run: [overlay]'s dotted keys as nested YAML, values written verbatim, and
/// `speech.enabled: false` so the `ask` tool never speaks on the host's speaker.
String renderOverlay(Map<String, String> overlay) {
  final root = <String, Object>{};
  for (final MapEntry(:key, :value) in {...overlay, 'speech.enabled': 'false'}.entries) {
    final parts = key.split('.');
    if (parts.any((part) => part.isEmpty)) throw ArgumentError.value(key, 'overlay', 'has an empty key segment');
    if (value.contains('\n')) throw ArgumentError.value(value, 'overlay[$key]', 'spans lines');
    var node = root;
    for (final part in parts.take(parts.length - 1)) {
      final child = node.putIfAbsent(part, () => <String, Object>{});
      if (child is! Map<String, Object>) throw ArgumentError.value(key, 'overlay', 'nests under a value');
      node = child;
    }
    if (node[parts.last] is Map) throw ArgumentError.value(key, 'overlay', 'is also a section');
    node[parts.last] = value;
  }
  final yaml = StringBuffer();
  void write(Map<String, Object> node, String indent) {
    for (final MapEntry(:key, :value) in node.entries) {
      final name = RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(key) ? key : jsonEncode(key);
      if (value is Map<String, Object>) {
        yaml.writeln('$indent$name:');
        write(value, '$indent  ');
      } else {
        yaml.writeln('$indent$name: $value');
      }
    }
  }

  write(root, '');
  return yaml.toString();
}

/// A detached run in `~/.ompanion/run/<id>/`.
final class _DetachedAccess implements RunAccess {
  _DetachedAccess(this._machine, this._run);

  final MachineRuntime _machine;
  final DetachedRun _run;

  @override
  bool get persistent => true;

  @override
  Future<RunChannel> attach({int? generation, int offset = 0, int inboxOffset = 0}) async {
    final ready = await _machine._ready();
    try {
      return await attachRun(
        ready.link,
        ready.probe,
        _run,
        tools: ready.tools,
        generation: generation,
        offset: offset,
        inboxOffset: inboxOffset,
      );
    } on Object catch (error, stack) {
      final List<DetachedRun> present;
      try {
        present = await runs.listRuns(ready.link, ready.probe);
      } on Object {
        // The link is down as well; the attach error says what happened.
        Error.throwWithStackTrace(error, stack);
      }
      if (!present.any((run) => run.id == _run.id)) throw RunGone('run ${_run.id} is gone from ${ready.link.label}');
      rethrow;
    }
  }

  @override
  Future<void> recordSession(String sessionPath) async {
    final connection = await _machine._connected();
    await recordRunSession(connection.link, connection.probe, _run, sessionPath);
  }

  @override
  Future<int?> stop() async {
    final connection = await _machine._connected();
    return stopRun(connection.link, connection.probe, _run);
  }

  @override
  Future<int> sessionFileSize(String sessionPath) async {
    final files = await (await _machine._connected()).link.files();
    try {
      final stat = await files.stat(toSftpPath(sessionPath));
      return stat?.size ?? (throw HostLinkException('no session file $sessionPath'));
    } finally {
      await files.close();
    }
  }

  @override
  Future<Uint8List> readSessionFile(String sessionPath, {int offset = 0, int? length}) async {
    final files = await (await _machine._connected()).link.files();
    try {
      return await files.read(toSftpPath(sessionPath), offset: offset, length: length);
    } finally {
      await files.close();
    }
  }

  @override
  Future<String> errorLog() async {
    final files = await (await _machine._connected()).link.files();
    try {
      final path = '${toSftpPath(_run.dir)}/err.log';
      final size = (await files.stat(path))?.size ?? 0;
      const tail = 8192;
      final from = size > tail ? size - tail : 0;
      return utf8.decode(await files.read(path, offset: from), allowMalformed: true);
    } finally {
      await files.close();
    }
  }
}

/// The control process: omp on an exec channel of the link, restarted by a new attach. In [bootstrap] mode it runs
/// on [bootstrapModel] with a placeholder key, and its channel refuses every model call.
final class _ControlAccess implements RunAccess {
  _ControlAccess(this._machine, {required this.bootstrap});

  final MachineRuntime _machine;
  final bool bootstrap;
  AttachedChannel? _channel;

  /// A credential was stored (`accounts.setKey`) or a login succeeded while in [bootstrap] mode.
  bool credentialsChanged = false;

  /// The omp binary and version the process was last started with.
  ({String path, String version})? launched;

  @override
  bool get persistent => false;

  @override
  Future<RunChannel> attach({int? generation, int offset = 0, int inboxOffset = 0}) async {
    final ready = await _machine._ready();
    final spec = RunSpec(
      omp: ready.probe.ompPath!,
      ompVersion: ready.probe.ompVersion!,
      cwd: ready.probe.home,
      companion: ready.companion,
      tools: ready.tools,
      overlay: _machine._overlay,
      args: [
        '--no-session',
        // `--api-key` is a runtime override for the model's provider (`keys.setRuntime`), never persisted.
        if (bootstrap) ...['--model', bootstrapModel, '--api-key', 'ompanion-bootstrap'],
      ],
    );
    final channel = _channel = await AttachedChannel.start(ready.link, ready.probe, spec);
    launched = (path: spec.omp, version: spec.ompVersion);
    return _ProcessChannel(channel, bootstrap ? this : null);
  }

  @override
  Future<void> recordSession(String sessionPath) =>
      throw StateError('the control session runs with --no-session and has no session file');

  @override
  Future<int?> stop() async {
    final channel = _channel;
    if (channel == null) return null;
    await channel.close();
    return channel.exitCode;
  }

  @override
  Future<String> errorLog() async => _channel?.stderr ?? '';

  @override
  Future<int> sessionFileSize(String sessionPath) =>
      throw StateError('the control session runs with --no-session and has no session file');

  @override
  Future<Uint8List> readSessionFile(String sessionPath, {int offset = 0, int? length}) =>
      throw StateError('the control session runs with --no-session and has no session file');
}

/// An attached omp process as a [RunChannel]: its output starts at `ready` and cannot be resumed. With a [_bootstrap]
/// access it refuses commands that make a model call, which would reach [bootstrapModel]'s provider with a
/// placeholder key, and watches for a stored credential or a finished login.
final class _ProcessChannel implements RunChannel {
  _ProcessChannel(this._channel, this._bootstrap);

  final AttachedChannel _channel;
  final _ControlAccess? _bootstrap;

  /// Ids of `accounts.setKey` calls and `login` requests in flight.
  final _credentialCalls = <String>{};

  static const _modelCommands = {'prompt', 'steer', 'follow_up', 'abort_and_prompt', 'compact', 'handoff'};

  /// Companion verbs that make a model call.
  static const _modelVerbs = {'btw', 'tree.navigate'};

  @override
  late final Stream<String> lines = _bootstrap == null ? _channel.lines : _channel.lines.map(_watch);

  @override
  Future<void> send(String line) {
    if (_bootstrap != null) _check(line);
    return _channel.send(line);
  }

  void _check(String line) {
    final command = jsonDecode(line);
    if (command is! Map<String, Object?>) return;
    final type = command['type'];
    if (command case {'type': 'login', 'id': final String id}) _credentialCalls.add(id);
    if (!_modelCommands.contains(type)) return;
    final message = command['message'];
    if (type == 'prompt' && message is String && message.startsWith('/ompx ')) {
      final call = jsonDecode(message.substring(6));
      if (call is Map<String, Object?> && !_modelVerbs.contains(call['verb'])) {
        if (call case {'verb': 'accounts.setKey', 'callId': final String callId}) _credentialCalls.add(callId);
        return;
      }
    }
    throw StateError('omp has no usable model on this machine yet; the control session refuses $type');
  }

  String _watch(String line) {
    if (_credentialCalls.isEmpty || !_credentialCalls.any(line.contains)) return line;
    final Object? frame;
    try {
      frame = jsonDecode(line);
    } on FormatException {
      return line;
    }
    switch (frame) {
      case {'type': 'ompx', 'kind': 'reply', 'callId': final String id, 'ok': final bool ok}
          when _credentialCalls.remove(id):
        if (ok) _bootstrap!.credentialsChanged = true;
      case {'type': 'response', 'command': 'login', 'id': final String id, 'success': final bool ok}
          when _credentialCalls.remove(id):
        if (ok) _bootstrap!.credentialsChanged = true;
    }
    return line;
  }

  @override
  Future<void> close() => _channel.close();

  @override
  int get offset => 0;

  @override
  int get generation => 1;

  @override
  int? get exitCode => _channel.exitCode;

  @override
  Stream<InboxLine> get inbox => const Stream.empty();

  @override
  int get inboxOffset => 0;
}

final class _Forward implements LocalForward {
  _Forward(this._server, this.remotePort, this._link) {
    _server.listen((socket) => unawaited(_accept(socket)));
  }

  final ServerSocket _server;
  final Future<HostLink> Function() _link;
  final _ends = <void Function()>{};
  void Function()? onClosed;
  bool _closed = false;

  @override
  final int remotePort;

  @override
  int get localPort => _server.port;

  Future<void> _accept(Socket socket) async {
    final HostSocket remote;
    try {
      remote = await (await _link()).connect('127.0.0.1', remotePort);
    } on Object {
      // The client sees its connection reset, as with `ssh -L` when the channel cannot open.
      socket.destroy();
      return;
    }
    var open = true;
    void end() {
      if (!open) return;
      open = false;
      socket.destroy();
      unawaited(remote.close());
    }

    if (_closed) return end();
    _ends.add(end);
    remote.input.listen(
      (data) {
        if (open) socket.add(data);
      },
      onDone: end,
      onError: (Object _) => end(),
    );
    socket.listen(
      (data) {
        if (open) remote.add(data);
      },
      onDone: end,
      onError: (Object _) => end(),
    );
    await remote.done;
    _ends.remove(end);
    end();
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close();
    for (final end in _ends.toList()) {
      end();
    }
    onClosed?.call();
  }
}
