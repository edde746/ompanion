import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import '../channel/run_log.dart';
import '../companion/companion_client.dart';
import '../rpc/exceptions.dart';
import '../rpc/frames.dart';
import '../rpc/json_fields.dart';
import '../rpc/results.dart';
import '../rpc/rpc_client.dart';
import '../ssh/ssh_link.dart';
import '../store/reducer.dart' hide dismissNotice, dismissRequest;
import '../store/reducer.dart' as store show dismissNotice, dismissRequest;
import '../store/session_view.dart';
import '../transport/line_channel.dart';
import 'live_session.dart';

/// How a [RunSession] reaches its omp process, and the host-side operations on its run. `MachineRuntime`
/// implements it for detached runs and for the control process.
abstract interface class RunAccess {
  /// True for a detached run, which outlives this device's channels: a new channel continues where the last one
  /// stopped, and the run's exit is final. False for omp on the channel itself (the control process): every attach
  /// starts a new process, and an exit starts the next one.
  bool get persistent;

  /// `out.jsonl` size from which a settled run is rotated; null when its log is never rotated.
  int? get rotateAt;

  /// A channel to the run. `out.jsonl` is read from [generation]/[offset] while [generation] is current, otherwise
  /// from the start of the current generation; `in.jsonl` from [inboxOffset].
  Future<RunChannel> attach({int? generation, int offset = 0, int inboxOffset = 0});

  /// Records [sessionPath] as the run's session in its `meta.json`.
  Future<void> recordSession(String sessionPath);

  /// Rotates `out.jsonl` when it still holds [rotateAt] bytes or more.
  Future<void> rotate();

  /// Stops omp gracefully and returns its exit code.
  Future<int?> stop();

  /// omp's stderr, for an omp that exited before it was ready.
  Future<String> errorLog();
}

/// omp exited before it was ready: no usable model, a bad flag, an unreadable session file. [stderr] is omp's
/// explanation.
final class OmpStartFailed implements Exception {
  OmpStartFailed(this.exitCode, this.stderr);

  final int? exitCode;
  final String stderr;

  @override
  String toString() =>
      'omp exited${exitCode == null ? '' : ' with code $exitCode'} before it was ready'
      '${stderr.trim().isEmpty ? '' : ': ${stderr.trim()}'}';
}

/// The run's omp exited; its log only shows what it did.
final class RunEnded implements Exception {
  RunEnded(this.runId, this.exitCode);

  final String runId;
  final int? exitCode;

  @override
  String toString() => 'run $runId ended${exitCode == null ? '' : ' with exit code $exitCode'}';
}

/// The run directory is gone from the machine (garbage collected, or never existed).
final class RunGone implements Exception {
  RunGone(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The machine has no usable omp: missing, or older than the minimum version.
final class OmpUnavailable implements Exception {
  OmpUnavailable(this.reason);

  final String reason;

  @override
  String toString() => reason;
}

/// Reconnect delay before [attempt] (from 1): 1 s doubling to 30 s, ±20 % jitter so devices that lost the same
/// link do not come back in lockstep.
Duration reconnectDelay(int attempt) {
  final seconds = min(30, 1 << min(attempt - 1, 5));
  return Duration(milliseconds: min(30000, (seconds * 1000 * (0.8 + 0.4 * _random.nextDouble())).round()));
}

final _random = Random();

typedef _Position = ({int generation, int offset, int inboxOffset});

/// A [LiveSession] over a [RunAccess]: attaches, builds the view from the replayed log plus RPC state, applies every
/// frame and every answer any device appends, keeps the view fresh (`stateStale`, `resyncReason`), records session
/// switches in `meta.json`, rotates a large log once settled, and reconnects after link loss.
final class RunSession implements LiveSession {
  RunSession({
    required this.runId,
    required this.cwd,
    required this._access,
    required this._deviceId,
    String? recordedPath,
    this._backoff = reconnectDelay,
    this.openTimeout = const Duration(seconds: 90),
  }) : _recorded = recordedPath,
       _sessionPath = recordedPath;

  @override
  final String runId;
  @override
  final String cwd;
  final RunAccess _access;
  final String _deviceId;
  final Duration Function(int attempt) _backoff;

  /// Limit for the first attach; [start] fails after it.
  final Duration openTimeout;

  /// Called once, when the session reaches [LinkClosed].
  void Function()? onClosed;

  /// The session file the run's `meta.json` names, as far as this device knows.
  String? _recorded;
  String? _sessionPath;
  CompanionHello? _hello;

  SessionView _view = SessionView();
  final _views = StreamController<SessionView>.broadcast();
  LinkState _linkState = const LinkConnecting();
  final _linkStates = StreamController<LinkState>.broadcast();

  _Attachment? _attached;
  late RpcClient _rpc;
  late CompanionClient _companion;

  /// Where the last channel stopped reading; the next one continues there.
  _Position? _resume;

  bool _closed = false;
  bool _stopping = false;

  /// While a view is rebuilt from RPC, frames and answers wait here to be applied on top.
  bool _seeding = false;
  final _frameBuffer = <RpcFrame>[];
  final _answerBuffer = <Map<String, Object?>>[];

  /// The session's append history (`get_entries`), extended after each settled run so live rows get entry ids.
  final _entries = <Map<String, Object?>>[];

  bool _refreshing = false;
  bool _refreshAgain = false;
  bool _catchingUp = false;
  bool _catchUpAgain = false;
  /// The `meta.json` update in flight.
  Future<void>? _recording;
  bool _rotating = false;
  Completer<void>? _wake;

  @override
  String? get sessionPath => _sessionPath;

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  LinkState get linkState => _linkState;

  @override
  Stream<LinkState> get linkStates => _linkStates.stream;

  @override
  RpcClient get rpc => _rpc;

  @override
  CompanionClient get companion => _companion;

  @override
  CompanionHello? get companionHello => _hello;

  /// The first attach. Throws [OmpStartFailed], [RunEnded], [RunGone], [OmpUnavailable], a transport error, or a
  /// [TimeoutException] after [openTimeout]; the session is closed then.
  Future<void> start() async {
    final _Attachment attachment;
    try {
      attachment = await _attach(_Mode.fresh).timeout(openTimeout);
      // A device opening this session file right after must find the run in meta.json.
      await _recording;
    } on Object catch (error) {
      _finish(LinkClosed(cause: error));
      rethrow;
    }
    if (!identical(attachment, _attached)) return;
    _setLinkState(const LinkLive());
    _react();
  }

  @override
  void dismissRequest(String id) => _setView(store.dismissRequest(_view, id));

  @override
  void dismissNotice(int seq) => _setView(store.dismissNotice(_view, seq));

  @override
  void reconnectNow() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  @override
  Future<void> detach() async {
    if (_closed) return;
    final attachment = _attached;
    _finish(const LinkClosed());
    await attachment?.close();
  }

  @override
  Future<void> stop() async {
    if (_closed) return;
    _stopping = true;
    final int? code;
    try {
      code = await _access.stop();
    } on Object {
      _stopping = false;
      rethrow;
    }
    final attachment = _attached;
    _finish(LinkClosed(exitCode: code));
    await attachment?.close();
  }

  // Attaching -------------------------------------------------------------------------------------------------------

  Future<_Attachment> _attach(_Mode mode) async {
    final resume = mode == _Mode.resume ? _resume : null;
    final channel = await _access.attach(
      generation: resume?.generation,
      offset: resume?.offset ?? 0,
      inboxOffset: resume?.inboxOffset ?? 0,
    );
    final tracked = _TrackedChannel(channel);
    final rpc = RpcClient(tracked, deviceId: _deviceId);
    final attachment = _Attachment(channel, tracked, rpc, CompanionClient(rpc));
    // A rotation while this device was away cut off frames it never read: rebuild from RPC.
    final seed = mode != _Mode.resume || channel.generation != resume?.generation;
    _seeding = seed;
    _frameBuffer.clear();
    _answerBuffer.clear();
    attachment.frames = rpc.frames.listen(
      (frame) => _onFrame(attachment, frame),
      onDone: () => _onFramesDone(attachment),
    );
    attachment.inbox = channel.inbox.listen(_onInbox, onError: attachment.fail);
    try {
      if (_closed) throw StateError('session $runId closed while attaching');
      // A channel at the very start of the log sees `ready`; any other point is mid-session.
      if (channel.generation == 1 && channel.offset == 0) {
        await rpc.start();
      } else {
        await rpc.attach();
      }
      if (seed) await _seed(attachment, fresh: mode == _Mode.fresh);
      if (_closed) throw StateError('session $runId closed while attaching');
    } on Object {
      // Frames applied straight to the view were read for good; buffered ones are read again by the next attach.
      if (!_seeding && mode == _Mode.resume) _resume = attachment.position;
      _seeding = false;
      _frameBuffer.clear();
      _answerBuffer.clear();
      await attachment.close();
      final code = channel.exitCode;
      if (code == null || _closed) rethrow;
      if (!attachment.sawReady && channel.generation == 1 && (resume == null || resume.offset == 0)) {
        throw OmpStartFailed(code, await _access.errorLog());
      }
      throw RunEnded(runId, code);
    }
    _attached = attachment;
    _rpc = attachment.rpc;
    _companion = attachment.companion;
    return attachment;
  }

  /// Rebuilds the view from RPC: `get_state`, the append history, subagents and the companion's snapshots.
  ///
  /// Frames before the `get_state` response happened before it, so the state already holds them. A [fresh] seed
  /// (the first on a process or device) replays them onto an empty view, minus their toasts: the log was read from
  /// the start of its generation. It also reads the commands, subscribes to subagent progress and looks for the
  /// companion. Any other seed (a resync, a rotation gap) keeps what RPC cannot list again: open dialogs, statuses,
  /// widgets, toasts, the goal and the commands. Frames after the response apply on top.
  Future<void> _seed(_Attachment attachment, {required bool fresh}) async {
    _seeding = true;
    final rpc = attachment.rpc;
    final companion = attachment.companion;
    final stateId = rpc.nextId();
    final state = rpc.request('get_state', const {}, stateId)..ignore();
    final entries = rpc.getEntries()..ignore();
    final subagents = rpc.getSubagents()..ignore();
    final subscribed = fresh ? (rpc.setSubagentSubscription(SubagentSubscription.progress)..ignore()) : null;
    Object? commands;
    var withCompanion = _hello != null;
    if (fresh) {
      commands = await rpc.request('get_available_commands');
      // An unknown slash command reaches the model as a prompt, so the companion is only called once registered.
      withCompanion = asJsonObject(commands, 'get_available_commands result')
          .objects('commands')
          .any((command) => command['name'] == 'ompx');
    }
    final results = await Future.wait<Object?>([
      state,
      entries,
      subagents,
      subscribed ?? Future<Object?>.value(),
      if (withCompanion) ...[
        if (fresh) _soft(companion.hello()),
        _soft(companion.call('state.snapshot')),
        _soft(companion.call('agents.list')),
      ],
    ]);
    final stateJson = asJsonObject(results[0], 'get_state result');
    final history = results[1] as RpcEntries;
    final subagentList = results[2] as List<Map<String, Object?>>;
    final companionResults = results.sublist(4).cast<(Object?, CompanionException?)>();
    final problems = [
      for (final (_, problem) in companionResults)
        if (problem != null) 'The companion failed ${problem.verb}: ${problem.message}',
    ];
    if (fresh) {
      _hello = withCompanion ? companionResults.first.$1 as CompanionHello? : null;
      if (!withCompanion) problems.add('omp runs without the companion extension; pause, queue and agents are off');
    }
    final snapshots = [
      for (final (result, _) in companionResults.skip(fresh && withCompanion ? 1 : 0))
        if (result != null) asJsonObject(result, 'companion snapshot'),
    ];

    final frames = List.of(_frameBuffer);
    final answers = List.of(_answerBuffer);
    _frameBuffer.clear();
    _answerBuffer.clear();
    var boundary = frames.indexWhere((frame) => frame is ResponseFrame && frame.id == stateId);
    if (boundary < 0) boundary = frames.length;
    var view = fresh ? SessionView() : _carryOver(_view);
    for (final frame in frames.take(boundary)) {
      view = _reduceFrame(view, frame);
    }
    // The seed is the resync any replayed session change asked for.
    view = view.copyWith(resyncReason: null, notices: fresh ? const [] : null);
    view = _safely(view, 'get_state', (view) => withState(view, stateJson));
    view = _safely(view, 'get_entries', (view) => withEntries(view, history.entries, leafId: history.leafId));
    if (commands != null) {
      view = _reduceSafe(view, {
        'type': 'available_commands_update',
        'commands': asJsonObject(commands, 'get_available_commands result')['commands'],
      });
    }
    view = _safely(view, 'get_subagents', (view) => withSubagents(view, subagentList));
    for (final snapshot in snapshots) {
      view = _safely(view, 'companion snapshot', (view) => withCompanionSnapshot(view, snapshot));
    }
    for (final frame in frames.skip(boundary)) {
      view = _reduceFrame(view, frame);
    }
    for (final answer in answers) {
      view = _reduceSafe(view, answer);
    }
    for (final problem in problems) {
      view = _notice(view, NoticeLevel.warning, problem);
    }
    _entries
      ..clear()
      ..addAll(history.entries);
    _seeding = false;
    _setView(view);
    _noteState(stateJson);
  }

  /// A companion call whose failure the seed reports as a toast instead of failing.
  static Future<(Object?, CompanionException?)> _soft(Future<Object?> call) async {
    try {
      return (await call, null);
    } on CompanionException catch (error) {
      return (null, error);
    }
  }

  static SessionView _safely(SessionView view, String what, SessionView Function(SessionView view) apply) {
    try {
      return apply(view);
    } on FormatException catch (error) {
      return _notice(view, NoticeLevel.error, 'omp sent a malformed $what result: ${error.message}');
    }
  }

  /// What a rebuilt view keeps: the process-level parts RPC cannot list again.
  static SessionView _carryOver(SessionView view) => SessionView(
    goal: view.goal,
    requests: view.requests,
    statuses: view.statuses,
    widgets: view.widgets,
    notices: view.notices,
    commandOutputs: view.commandOutputs,
    commands: view.commands,
    agents: view.agents,
    nextSeq: view.nextSeq,
    settledRequestIds: view.settledRequestIds,
  );

  // Frames ----------------------------------------------------------------------------------------------------------

  void _onFrame(_Attachment attachment, RpcFrame frame) {
    if (frame is ReadyFrame) attachment.sawReady = true;
    if (_closed) return;
    if (_seeding) {
      _frameBuffer.add(frame);
      return;
    }
    _setView(_reduceFrame(_view, frame));
    // Replayed frames of a resuming channel are history; only live ones trigger work.
    if (!identical(attachment, _attached)) return;
    if (frame is SessionSettledFrame) _onSettled(attachment);
    _react();
  }

  /// Dialog answers any device appended to `in.jsonl`, this one's included: every device closes the dialog.
  void _onInbox(InboxLine line) {
    // Cheap filter first: prompts with images make long lines.
    if (_closed || !line.line.contains('"extension_ui_response"')) return;
    final Object? json;
    try {
      json = jsonDecode(line.line);
    } on FormatException {
      // omp answers an unparsable line itself, with a `parse` error response in out.jsonl.
      return;
    }
    if (json is! Map<String, Object?> || json['type'] != 'extension_ui_response' || json['id'] is! String) return;
    if (_seeding) {
      _answerBuffer.add(json);
    } else {
      _setView(_reduceSafe(_view, json));
    }
  }

  SessionView _reduceFrame(SessionView view, RpcFrame frame) {
    var next = _reduceSafe(view, frame.raw);
    // Companion frames on the fallback channel reach the reducer unwrapped (docs/contracts/ompx.md).
    if (frame case UiSetStatusRequest(statusKey: companionStatusKey, :final statusText?)) {
      final Object? inner;
      try {
        inner = jsonDecode(statusText);
      } on FormatException catch (error) {
        return _notice(next, NoticeLevel.error, 'The companion sent a malformed frame: ${error.message}');
      }
      if (inner is Map<String, Object?> && inner['type'] == 'ompx') next = _reduceSafe(next, inner);
    }
    return next;
  }

  static SessionView _reduceSafe(SessionView view, Map<String, Object?> frame) {
    try {
      return reduce(view, frame);
    } on FormatException catch (error) {
      return _notice(view, NoticeLevel.error, 'omp sent a malformed ${frame['type']} frame: ${error.message}');
    }
  }

  /// Follows what the latest view asks for: a rebuild after a session change, or `get_state` news.
  void _react() {
    final attachment = _attached;
    if (_closed || _seeding || attachment == null || _linkState is! LinkLive) return;
    if (_view.resyncReason != null) {
      unawaited(_resync(attachment));
    } else if (_view.stateStale) {
      unawaited(_refresh(attachment));
    }
  }

  Future<void> _resync(_Attachment attachment) async {
    if (_seeding) return;
    try {
      await _seed(attachment, fresh: false);
    } on Object catch (error) {
      _seeding = false;
      // These frames were read from the log; apply them to the old view rather than lose them.
      var view = _view;
      for (final frame in _frameBuffer) {
        view = _reduceFrame(view, frame);
      }
      for (final answer in _answerBuffer) {
        view = _reduceSafe(view, answer);
      }
      _frameBuffer.clear();
      _answerBuffer.clear();
      // A closed client means the channel ended; resyncReason stays set, so the next attachment resyncs.
      if (error is! RpcClosedException) {
        view = _notice(view.copyWith(resyncReason: null), NoticeLevel.error, 'Reloading the session failed: $error');
      }
      _setView(view);
      return;
    }
    _react();
  }

  Future<void> _refresh(_Attachment attachment) async {
    if (_refreshing) {
      _refreshAgain = true;
      return;
    }
    _refreshing = true;
    try {
      do {
        _refreshAgain = false;
        final state = asJsonObject(await attachment.rpc.request('get_state'), 'get_state result');
        // A seed in the meantime read get_state itself.
        if (_closed || _seeding || !identical(attachment, _attached)) return;
        _setView(withState(_view, state));
        _noteState(state);
      } while (_refreshAgain);
    } on RpcClosedException {
      // The channel ended; the view stays stale, and the next attachment refreshes it.
      return;
    } on Object catch (error) {
      _setView(_notice(_view.copyWith(stateStale: false), NoticeLevel.error, 'Reading the session state failed: $error'));
    } finally {
      _refreshing = false;
    }
    _react();
  }

  void _onSettled(_Attachment attachment) {
    final at = _access.rotateAt;
    if (at != null && !_rotating && attachment.tracked.offset >= at) {
      _rotating = true;
      unawaited(_rotate());
    }
    unawaited(_catchUpEntries(attachment));
  }

  Future<void> _rotate() async {
    try {
      await _access.rotate();
    } on Object catch (error) {
      if (_linkState is LinkLive) _warn('Rotating the session log on the machine failed: $error');
    } finally {
      _rotating = false;
    }
  }

  /// Entries appended by the run that just settled, so its rows get their entry ids (branching needs them).
  Future<void> _catchUpEntries(_Attachment attachment) async {
    if (_catchingUp) {
      _catchUpAgain = true;
      return;
    }
    _catchingUp = true;
    try {
      do {
        _catchUpAgain = false;
        if (_seeding) return;
        final result = await attachment.rpc.getEntries(since: _entries.lastOrNull?.optString('id'));
        if (_closed || _seeding || !identical(attachment, _attached)) return;
        if (result.entries.isEmpty) continue;
        _entries.addAll(result.entries);
        _setView(_safely(_view, 'get_entries', (view) => withEntries(view, _entries, leafId: result.leafId)));
      } while (_catchUpAgain);
    } on RpcCommandException catch (error) {
      if (error.code == 'unknown_since') {
        // The history this device holds belongs to another session file now.
        _setView(_view.copyWith(resyncReason: 'entries'));
      } else {
        _warn('Reading the session entries failed: ${error.message}');
      }
    } on RpcClosedException {
      // The channel ended; the next attachment reads the whole history.
      return;
    } finally {
      _catchingUp = false;
    }
    _react();
  }

  /// Keeps [sessionPath] and the run's `meta.json` on omp's current file.
  void _noteState(Map<String, Object?> state) {
    final file = state.optString('sessionFile');
    if (file == null) return;
    _sessionPath = file;
    if (!_access.persistent || file == _recorded || _recording != null) return;
    _recording = _record(file);
  }

  Future<void> _record(String file) async {
    var current = file;
    try {
      // omp may have switched files again while meta.json was being updated.
      while (true) {
        await _access.recordSession(current);
        _recorded = current;
        final latest = _sessionPath;
        if (latest == null || latest == current || _closed) return;
        current = latest;
      }
    } on Object catch (error) {
      if (!_closed && _linkState is! LinkReconnecting) _warn('Recording the session file on the machine failed: $error');
    } finally {
      _recording = null;
    }
  }

  // Link loss -------------------------------------------------------------------------------------------------------

  void _onFramesDone(_Attachment attachment) {
    // The client stops before it closes its frames, so `done` has settled by now.
    unawaited(
      attachment.rpc.done.then(
        (_) => _ended(attachment, attachment.failure),
        onError: (Object error) => _ended(attachment, attachment.failure ?? error),
      ),
    );
  }

  void _ended(_Attachment attachment, Object? error) {
    if (_closed || !identical(attachment, _attached)) return;
    _attached = null;
    _resume = attachment.position;
    unawaited(attachment.close());
    final code = attachment.channel.exitCode;
    if (_stopping || (code != null && _access.persistent)) {
      _finish(LinkClosed(exitCode: code));
      return;
    }
    if (error is RpcProtocolException) {
      _finish(LinkClosed(cause: error));
      return;
    }
    final gap = error is RpcClosedException && error.cause is RunLogGap;
    unawaited(_reconnect(error ?? RpcClosedException('the channel to run $runId ended'), reseed: gap));
  }

  Future<void> _reconnect(Object cause, {required bool reseed}) async {
    var attempt = 1;
    var lastCause = cause;
    final mode = !_access.persistent
        ? _Mode.fresh
        : reseed
        ? _Mode.reseed
        : _Mode.resume;
    while (!_closed) {
      // A rotation gap is no link problem: read the new generation at once.
      final delay = reseed && attempt == 1 ? Duration.zero : _backoff(attempt);
      _setLinkState(LinkReconnecting(attempt: attempt, nextTry: DateTime.now().add(delay), cause: lastCause));
      await _sleep(delay);
      if (_closed) return;
      final _Attachment attachment;
      try {
        attachment = await _attach(mode);
      } on Object catch (error) {
        if (_closed) return;
        if (error is RunEnded) {
          _finish(LinkClosed(exitCode: error.exitCode));
          return;
        }
        if (_permanent(error)) {
          _finish(LinkClosed(cause: error));
          return;
        }
        lastCause = error;
        attempt++;
        continue;
      }
      // The new channel may already have ended, and another reconnect taken over.
      if (!identical(attachment, _attached)) return;
      _setLinkState(const LinkLive());
      // Runs that settled while this device was away get their entry ids.
      if (mode == _Mode.resume) unawaited(_catchUpEntries(attachment));
      _react();
      return;
    }
  }

  Future<void> _sleep(Duration delay) async {
    if (delay <= Duration.zero) return;
    final wake = _wake = Completer<void>();
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    if (identical(_wake, wake)) _wake = null;
  }

  /// Reconnecting cannot help: credentials or host key refused, the run gone, omp missing or unable to start.
  static bool _permanent(Object error) => switch (error) {
    OmpStartFailed() || RunGone() || OmpUnavailable() => true,
    SshConnectException(:final failure) =>
      failure == SshFailure.authFailed ||
          failure == SshFailure.hostKeyRejected ||
          failure == SshFailure.keyUnavailable,
    _ => false,
  };

  void _finish(LinkClosed state) {
    if (_closed) return;
    _closed = true;
    reconnectNow();
    final attachment = _attached;
    _attached = null;
    if (attachment != null) unawaited(attachment.close());
    _setLinkState(state);
    unawaited(_views.close());
    unawaited(_linkStates.close());
    onClosed?.call();
  }

  // View plumbing ---------------------------------------------------------------------------------------------------

  void _setView(SessionView view) {
    if (identical(view, _view)) return;
    _view = view;
    if (!_views.isClosed) _views.add(view);
  }

  void _setLinkState(LinkState state) {
    _linkState = state;
    if (!_linkStates.isClosed) _linkStates.add(state);
  }

  void _warn(String message) => _setView(_notice(_view, NoticeLevel.warning, message));

  static SessionView _notice(SessionView view, NoticeLevel level, String message) {
    final notices = [...view.notices, MessageNotice(view.nextSeq, level: level, message: message, source: 'omp-app')];
    return view.copyWith(
      notices: UnmodifiableListView(
        notices.length <= SessionView.maxNotices ? notices : notices.sublist(notices.length - SessionView.maxNotices),
      ),
      nextSeq: view.nextSeq + 1,
    );
  }
}

enum _Mode {
  /// First attach: the log from the start of its generation, a view built from nothing.
  fresh,

  /// Same generation as before: the frames missed while away apply to the view as it is.
  resume,

  /// The log was rotated past this device: the current generation, and a view rebuilt from RPC.
  reseed,
}

/// One channel to the run with its clients.
final class _Attachment {
  _Attachment(this.channel, this.tracked, this.rpc, this.companion);

  final RunChannel channel;
  final _TrackedChannel tracked;
  final RpcClient rpc;
  final CompanionClient companion;
  StreamSubscription<RpcFrame>? frames;
  StreamSubscription<InboxLine>? inbox;
  bool sawReady = false;

  /// Why the channel broke, when the inbox side noticed first.
  Object? failure;
  Future<void>? _closing;

  _Position get position => (generation: tracked.generation, offset: tracked.offset, inboxOffset: channel.inboxOffset);

  void fail(Object error) {
    failure ??= error;
    unawaited(close());
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    await companion.close();
    await rpc.close();
    await Future.wait([?frames?.cancel(), ?inbox?.cancel()]);
  }
}

/// Hands the run's lines to the RPC client and remembers the log position after the last complete frame: a channel
/// resumed inside an `rpc_chunk` sequence would drop the rest of that frame.
final class _TrackedChannel implements LineChannel {
  _TrackedChannel(this.channel) : generation = channel.generation, offset = channel.offset;

  final RunChannel channel;
  int generation;
  int offset;

  @override
  late final Stream<String> lines = channel.lines.map((line) {
    if (_endsFrame(line)) {
      generation = channel.generation;
      offset = channel.offset;
    }
    return line;
  });

  @override
  Future<void> send(String line) => channel.send(line);

  @override
  Future<void> close() => channel.close();

  static final _chunkIndex = RegExp(r'"index":(\d+),"count":(\d+)');

  /// Any line but a chunk before the last of its sequence. omp writes a chunk's metadata ahead of its data.
  static bool _endsFrame(String line) {
    if (!line.startsWith('{"type":"rpc_chunk"')) return true;
    final match = _chunkIndex.firstMatch(line.length > 400 ? line.substring(0, 400) : line);
    return match != null && int.parse(match[1]!) == int.parse(match[2]!) - 1;
  }
}
