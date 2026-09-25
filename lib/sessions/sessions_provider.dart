import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';

import '../models/machine.dart';
import '../providers/machines_provider.dart';
import '../services/machine_connector.dart';
import 'composer_draft.dart';
import 'connect_prompt_queue.dart';
import 'exec_runs.dart';
import 'oauth_callback.dart';

/// The session files and live runs of one machine, as last listed.
final class SessionListing {
  const SessionListing({this.sessions = const [], this.loading = false, this.error, this.loadedAt});

  /// Newest first.
  final List<SessionSummary> sessions;
  final bool loading;

  /// Why the last listing failed; the previous [sessions] stay.
  final Object? error;
  final DateTime? loadedAt;

  SessionListing copyWith({List<SessionSummary>? sessions, bool? loading, Object? error, DateTime? loadedAt}) =>
      SessionListing(
        sessions: sessions ?? this.sessions,
        loading: loading ?? this.loading,
        error: error,
        loadedAt: loadedAt ?? this.loadedAt,
      );
}

/// Machine runtimes and the sessions this device has open.
///
/// One [MachineRuntime] per machine, created on first use. Its connections go through [MachineConnector]
/// with prompts from [prompts], so a reconnect in the background asks for a password or a host key once the
/// app is in the foreground again.
class SessionsProvider extends ChangeNotifier {
  SessionsProvider({
    required this._connector,
    required this._machines,
    required this.deviceId,
    required this._companionBytes,
  }) {
    _machines.addListener(_onMachinesChanged);
  }

  final MachineConnector _connector;
  final MachinesProvider _machines;
  final Future<List<int>> Function(String ompVersion) _companionBytes;

  /// Stable per app install (`Prefs.deviceId`).
  final String deviceId;

  final ConnectPromptQueue prompts = ConnectPromptQueue();

  final Map<String, MachineRuntime> _runtimes = {};
  final Map<String, SessionListing> _listings = {};
  final Map<String, Future<List<RpcModel>>> _models = {};
  final List<LiveSession> _open = [];
  final Map<LiveSession, String> _machineIds = {};
  final Map<LiveSession, ComposerDraft> _drafts = {};
  final Map<LiveSession, ExecRuns> _execRuns = {};
  final Map<String, LocalForward> _oauthForwards = {};
  LiveSession? _active;
  bool _disposed = false;

  /// The runtime of [machine], created on first use.
  MachineRuntime runtimeFor(Machine machine) => _runtimes.putIfAbsent(
    machine.id,
    () => MachineRuntime(
      // The latest record, so an edited machine dials its new address on the next connect.
      connect: () => _connector.open(_machines.byId(machine.id) ?? machine, prompts.promptsFor(machine)),
      deviceId: deviceId,
      companionBytes: _companionBytes,
    ),
  );

  /// The session the center pane shows, or null.
  LiveSession? get active => _active;

  Machine? get activeMachine {
    final session = _active;
    return session == null ? null : machineOf(session);
  }

  /// Sessions this device has open, oldest first.
  List<LiveSession> get openSessions => List.unmodifiable(_open);

  Machine? machineOf(LiveSession session) {
    final id = _machineIds[session];
    return id == null ? null : _machines.byId(id);
  }

  /// The composer draft of [session], kept while the session is open.
  ComposerDraft draftOf(LiveSession session) => _drafts.putIfAbsent(session, ComposerDraft.new);

  /// Puts [text] and [images] into [session]'s composer, replacing its draft: `set_editor_text`, a branch's
  /// user message, a tree navigation's `editorText`.
  void setDraft(LiveSession session, String text, {List<RpcImage> images = const []}) =>
      draftOf(session).replace(text, images: images);

  /// The `!` / `$` runs started from [session]'s composer.
  ExecRuns execRunsOf(LiveSession session) => _execRuns.putIfAbsent(session, ExecRuns.new);

  /// Opens [request] on [machine] and makes it [active]. A session this device already has open is selected
  /// instead of opened twice; one whose link closed is opened again in its place.
  Future<LiveSession> open(Machine machine, SessionOpen request) async {
    final same = _open.where((s) => _machineIds[s] == machine.id && _opens(request, s)).firstOrNull;
    if (same != null) {
      if (same.linkState is LinkClosed) return reopen(same);
      select(same);
      return same;
    }
    final session = await runtimeFor(machine).open(request);
    if (_disposed) {
      await session.detach();
      return session;
    }
    // The runtime hands out one LiveSession per run.
    if (!_open.contains(session)) {
      _open.add(session);
      _machineIds[session] = machine.id;
    }
    _active = session;
    notifyListeners();
    // A new session or a launched run shows up in the listing.
    unawaited(refresh(machine));
    return session;
  }

  static bool _opens(SessionOpen request, LiveSession session) => switch (request) {
    ResumeSession(:final sessionPath) => session.sessionPath == sessionPath,
    AttachRun(:final runId) => session.runId == runId,
    NewSession() => false,
  };

  /// Opens the session again after its link closed (the omp process exited or reconnecting gave up),
  /// replacing [session] in [openSessions].
  Future<LiveSession> reopen(LiveSession session) async {
    final machine = machineOf(session);
    if (machine == null) throw StateError('the machine of this session was deleted');
    final path = session.sessionPath;
    final request = path == null ? AttachRun(session.runId) : ResumeSession(path);
    final replacement = await runtimeFor(machine).open(request);
    if (identical(replacement, session)) {
      select(session);
      return session;
    }
    final index = _open.indexOf(session);
    if (index < 0) {
      _open.add(replacement);
    } else {
      _open[index] = replacement;
    }
    _machineIds.remove(session);
    _machineIds[replacement] = machine.id;
    final draft = _drafts.remove(session);
    if (draft != null) _drafts[replacement] = draft;
    _disposeLater(_execRuns.remove(session));
    if (_active == session || _active == null) _active = replacement;
    notifyListeners();
    unawaited(session.detach());
    unawaited(refresh(machine));
    return replacement;
  }

  void select(LiveSession session) {
    if (!_open.contains(session) || identical(_active, session)) return;
    _active = session;
    notifyListeners();
  }

  /// Detaches this device from [session]; the omp process keeps running on the machine.
  Future<void> detach(LiveSession session) async {
    _forget(session);
    await session.detach();
  }

  /// Stops [session]'s omp process, then forgets it.
  Future<void> stop(LiveSession session) async {
    final machine = machineOf(session);
    _forget(session);
    await session.stop();
    if (machine != null) unawaited(refresh(machine));
  }

  /// The machine's shared control process, for settings, roles, accounts, login, models and listings.
  Future<LiveSession> control(Machine machine) => runtimeFor(machine).control();

  SessionListing listingOf(Machine machine) => _listings[machine.id] ?? const SessionListing();

  /// Connects when needed, probes, and lists the machine's sessions and live runs. Failures land in
  /// [listingOf]`.error` and in the runtime's status.
  Future<void> refresh(Machine machine) async {
    final runtime = runtimeFor(machine);
    _setListing(machine.id, listingOf(machine).copyWith(loading: true, error: listingOf(machine).error));
    try {
      if (runtime.status is! MachineOnline) await runtime.connectAndProbe();
      if (runtime.status is! MachineOnline) {
        _setListing(machine.id, listingOf(machine).copyWith(loading: false));
        return;
      }
      final sessions = await runtime.listSessions();
      _setListing(
        machine.id,
        SessionListing(sessions: sessions, loadedAt: DateTime.now()),
      );
    } on Object catch (error) {
      _setListing(machine.id, listingOf(machine).copyWith(loading: false, error: error));
    }
  }

  /// `get_available_models` of [machine], cached per machine and omp version: the list is over 2 MB and the
  /// same for every session of one omp install (docs/PLAN.md D4).
  Future<List<RpcModel>> models(Machine machine, RpcClient rpc, {bool refresh = false}) {
    final version = switch (runtimeFor(machine).status) {
      MachineOnline(:final probe) => probe.ompVersion,
      _ => null,
    };
    final key = '${machine.id}@$version';
    if (refresh) _models.remove(key);
    return _models.putIfAbsent(key, () {
      final models = rpc.getAvailableModels();
      // A failed fetch is not cached; the caller still gets the error.
      unawaited(models.then((_) {}, onError: (Object _) => _models.remove(key)));
      return models;
    });
  }

  /// For a login URL whose OAuth callback is the machine's loopback, forwards the same port on this device
  /// to it, so the browser here can finish the login. Null on this computer and for URLs without a loopback
  /// callback. A forward stays up for [oauthForwardLifetime]; a second login reuses it.
  Future<LocalForward?> forwardOAuthCallback(Machine machine, String url) async {
    if (machine is LocalMachine) return null;
    final port = loopbackRedirectPort(url);
    if (port == null) return null;
    final key = '${machine.id}:$port';
    final existing = _oauthForwards[key];
    if (existing != null) return existing;
    final forward = await runtimeFor(machine).forwardLocal(port, localPort: port);
    _oauthForwards[key] = forward;
    Timer(oauthForwardLifetime, () {
      if (!identical(_oauthForwards[key], forward)) return;
      _oauthForwards.remove(key);
      unawaited(forward.close());
    });
    return forward;
  }

  static const oauthForwardLifetime = Duration(minutes: 15);

  void _setListing(String machineId, SessionListing listing) {
    if (_disposed) return;
    _listings[machineId] = listing;
    notifyListeners();
  }

  /// The chat screen may still hold [notifier] in this frame.
  static void _disposeLater(ChangeNotifier? notifier) {
    if (notifier != null) SchedulerBinding.instance.addPostFrameCallback((_) => notifier.dispose());
  }

  void _forget(LiveSession session) {
    _machineIds.remove(session);
    _disposeLater(_drafts.remove(session));
    _disposeLater(_execRuns.remove(session));
    final index = _open.indexOf(session);
    if (index < 0) return;
    _open.removeAt(index);
    if (identical(_active, session)) {
      _active = _open.isEmpty ? null : _open[index.clamp(0, _open.length - 1)];
    }
    notifyListeners();
  }

  void _onMachinesChanged() {
    final ids = {for (final machine in _machines.machines) machine.id};
    final gone = [
      for (final id in _runtimes.keys)
        if (!ids.contains(id)) id,
    ];
    if (gone.isEmpty) return;
    for (final id in gone) {
      prompts.cancelFor(id);
      for (final session in [
        for (final entry in _machineIds.entries)
          if (entry.value == id) entry.key,
      ]) {
        _forget(session);
        unawaited(session.detach());
      }
      _listings.remove(id);
      _models.removeWhere((key, _) => key.startsWith('$id@'));
      unawaited(_runtimes.remove(id)!.dispose());
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _machines.removeListener(_onMachinesChanged);
    for (final runtime in _runtimes.values) {
      unawaited(runtime.dispose());
    }
    _runtimes.clear();
    for (final forward in _oauthForwards.values) {
      unawaited(forward.close());
    }
    _oauthForwards.clear();
    prompts.dispose();
    super.dispose();
  }
}
