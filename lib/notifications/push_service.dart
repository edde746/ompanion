import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';

import '../models/machine.dart';
import '../providers/machines_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/shell_provider.dart';
import '../sessions/sessions_provider.dart';
import '../sessions/show_session.dart';

/// Whether this build can receive push notifications, and why not.
typedef PushAvailability = ({bool available, String? reason});

typedef _Registration = ({PushPlatform platform, String fid, String key});

/// Phone push (docs/contracts/push.md) on Android and iOS: the native FCM code behind the `ompanion/push` channel,
/// this phone's registration file on the machines, and the session the phone shows, whose messages native code keeps
/// out of the notification shade.
///
/// While push is on, every machine gets the registration each time it connects, and the connected ones again when
/// its Firebase installation ID (FID) or the wanted kinds change. Turning push off removes it from the connected
/// machines and from the others on their next connect ([Prefs.pushRemovals]). A failed write or removal lands on
/// [failures].
class PushService extends ChangeNotifier with WidgetsBindingObserver {
  PushService._(this._sessions, this._shell, this._machines, this._settings) : _kinds = _wantedKinds(_settings);

  factory PushService.following({
    required SessionsProvider sessions,
    required ShellProvider shell,
    required MachinesProvider machines,
    required SettingsProvider settings,
  }) {
    final push = PushService._(sessions, shell, machines, settings);
    _channel.setMethodCallHandler(push._onCall);
    sessions.addListener(push._onSessions);
    shell.addListener(push._syncVisible);
    machines.addListener(push._follow);
    settings.addListener(push._onSettings);
    WidgetsBinding.instance.addObserver(push);
    push._follow();
    push._syncVisible();
    unawaited(push._start());
    return push;
  }

  static const _channel = MethodChannel('ompanion/push');

  final SessionsProvider _sessions;
  final ShellProvider _shell;
  final MachinesProvider _machines;
  final SettingsProvider _settings;
  final _taps = StreamController<SessionTarget>.broadcast();
  final _failures = StreamController<(Machine, Object)>.broadcast();

  /// Each machine's runtime and the subscription to its status; the runtime is replaced when the machine's route
  /// changes.
  final Map<String, (MachineRuntime, StreamSubscription<MachineStatus>)> _statuses = {};

  /// The registration writes and removals of each machine, one after the other.
  final Map<String, Future<void>> _queues = {};
  Set<NotificationKind> _kinds;
  _Registration? _registration;
  PushAvailability? _availability;
  SessionTarget? _visible;
  bool _busy = false;
  bool _lostKey = false;
  bool _disposed = false;

  /// Push is on for this phone.
  bool get enabled => _settings.get(Prefs.pushNotifications);

  /// Null until [checkAvailability] answered.
  PushAvailability? get availability => _availability;

  /// Push is being turned on or off.
  bool get busy => _busy;

  /// Push was on, but native code had no key any more: a restore from a backup brings the setting and not the key,
  /// which stays on the phone it was made on. Push was turned off then, and the machines' registrations, which name
  /// that key, go on their next connect.
  bool get lostKey => _lostKey;

  /// Taps on notifications while the app runs.
  Stream<SessionTarget> get taps => _taps.stream;

  /// Registration writes and removals that failed, with their machine.
  Stream<(Machine, Object)> get failures => _failures.stream;

  /// The tap on a notification that launched the app, once. Native code holds taps until this is first called.
  Future<SessionTarget?> takeLaunchTap() async {
    final tap = await _channel.invokeMethod<Object?>('takeLaunchTap');
    return tap == null ? null : SessionTarget.fromJson(tap);
  }

  Future<void> checkAvailability() async {
    final status = await _channel.invokeMapMethod<String, Object?>('status');
    final available = status?['available'];
    final reason = status?['reason'];
    if (available is! bool || reason is! String?) throw FormatException('push status: $status');
    _availability = (available: available, reason: reason);
    _notify();
  }

  /// Asks for permission, makes the key and registers the installation for messaging natively, then writes the
  /// registration to the connected machines. Throws [PlatformException] `denied`, `unavailable` or `failed`.
  Future<void> enable() => _whileBusy(() async {
    _registration = _decodeRegistration(
      await _channel.invokeMethod<Object?>('enable', {'deviceId': _sessions.deviceId}),
    );
    _lostKey = false;
    await _settings.set(Prefs.pushRemovals, const <String>[]);
    await _settings.set(Prefs.pushNotifications, true);
    _syncOnline();
  });

  /// Unregisters and deletes the installation and the key natively, then removes the registration from the machines.
  Future<void> disable() => _whileBusy(() async {
    await _channel.invokeMethod<void>('disable');
    _registration = null;
    await _settings.set(Prefs.pushRemovals, [for (final machine in _machines.machines) machine.id]);
    await _settings.set(Prefs.pushNotifications, false);
    _syncOnline();
  });

  /// The companion's `notify.test` on [machine], once its registration is written. Throws [CompanionException]
  /// `not_found` without a registration there, `failed` when the relay refused.
  Future<void> sendTest(Machine machine) async {
    await _queues[machine.id];
    final control = await _sessions.control(machine);
    await control.companion.call('notify.test');
  }

  /// Whether [machine] is connected, so [sendTest] can reach it.
  bool isOnline(Machine machine) => _sessions.runtimeFor(machine).status is MachineOnline;

  Future<void> _start() async {
    if (enabled) await _adopt(await _channel.invokeMethod<Object?>('registration'));
  }

  /// Takes native code's registration while push is on; none means the key is gone ([lostKey]).
  Future<void> _adopt(Object? json) async {
    final registration = _decodeRegistration(json);
    if (registration == null) {
      _lostKey = true;
      await _settings.set(Prefs.pushRemovals, [for (final machine in _machines.machines) machine.id]);
      await _settings.set(Prefs.pushNotifications, false);
      _notify();
    } else {
      _registration = registration;
    }
    _syncOnline();
  }

  Future<Object?> _onCall(MethodCall call) async {
    switch (call.method) {
      case 'fid':
        await _onFid(call.arguments);
      case 'tap':
        _taps.add(SessionTarget.fromJson(call.arguments));
      default:
        throw MissingPluginException('ompanion/push has no method ${call.method}');
    }
    return null;
  }

  Future<void> _onFid(Object? arguments) async {
    if (!enabled) return;
    final fid = arguments is Map ? arguments['fid'] : null;
    if (fid is! String) throw FormatException('push fid: $arguments');
    final registration = _registration;
    if (registration == null) return _adopt(await _channel.invokeMethod<Object?>('registration'));
    _registration = (platform: registration.platform, fid: fid, key: registration.key);
    _syncOnline();
  }

  void _onSettings() {
    final kinds = _wantedKinds(_settings);
    if (kinds.length == _kinds.length && kinds.containsAll(_kinds)) return;
    _kinds = kinds;
    if (enabled) _syncOnline();
  }

  void _onSessions() {
    _follow();
    _syncVisible();
  }

  /// Subscribes to every machine's runtime status: a machine that comes online gets its registration.
  void _follow() {
    final ids = <String>{};
    for (final machine in _machines.machines) {
      ids.add(machine.id);
      final runtime = _sessions.runtimeFor(machine);
      final current = _statuses[machine.id];
      if (identical(current?.$1, runtime)) continue;
      if (current != null) unawaited(current.$2.cancel());
      _statuses[machine.id] = (
        runtime,
        runtime.statuses.listen((status) {
          if (status is MachineOnline) _sync(machine.id);
        }),
      );
      if (runtime.status is MachineOnline) _sync(machine.id);
    }
    for (final id in [..._statuses.keys.where((id) => !ids.contains(id))]) {
      unawaited(_statuses.remove(id)!.$2.cancel());
    }
  }

  void _syncOnline() {
    for (final machine in _machines.machines) {
      if (isOnline(machine)) _sync(machine.id);
    }
  }

  void _sync(String machineId) {
    _queues[machineId] = (_queues[machineId] ?? Future<void>.value())
        .then((_) => _apply(machineId))
        .then<void>(
          (_) {},
          onError: (Object error) {
            final machine = _machines.byId(machineId);
            if (machine != null && !_failures.isClosed) _failures.add((machine, error));
          },
        );
  }

  /// Writes or removes [machineId]'s registration as push stands now; a machine that went offline meanwhile gets it
  /// on its next connect.
  Future<void> _apply(String machineId) async {
    final machine = _machines.byId(machineId);
    if (machine == null || _disposed) return;
    final runtime = _sessions.runtimeFor(machine);
    if (runtime.status is! MachineOnline) return;
    final registration = _registration;
    if (enabled) {
      if (registration == null) return;
      await writePushRegistration(
        runtime.link,
        PushRegistration(
          deviceId: _sessions.deviceId,
          machineId: machine.id,
          machineName: machine.name,
          platform: registration.platform,
          fid: registration.fid,
          key: registration.key,
          kinds: _kinds,
        ),
      );
    } else if (_settings.get(Prefs.pushRemovals).contains(machineId)) {
      await removePushRegistration(runtime.link, _sessions.deviceId);
      await _settings.set(Prefs.pushRemovals, [
        for (final id in _settings.get(Prefs.pushRemovals))
          if (id != machineId) id,
      ]);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _syncVisible();

  /// Tells native code which session the phone shows while in the foreground, and clears that session's
  /// notifications: it is being read.
  void _syncVisible() {
    final foreground = WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    final session = foreground && _shell.selection is SessionSelection ? _sessions.active : null;
    final machine = session == null ? null : _sessions.machineOf(session);
    final visible = session == null || machine == null
        ? null
        : SessionTarget(machineId: machine.id, runId: session.runId, sessionPath: session.sessionPath);
    if (visible == _visible) return;
    _visible = visible;
    unawaited(_channel.invokeMethod<void>('setVisible', visible?.toJson()));
    if (visible != null) {
      unawaited(_channel.invokeMethod<void>('clear', {'machineId': visible.machineId, 'runId': visible.runId}));
    }
  }

  Future<void> _whileBusy(Future<void> Function() body) async {
    _busy = true;
    _notify();
    try {
      await body();
    } finally {
      _busy = false;
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  static Set<NotificationKind> _wantedKinds(SettingsProvider settings) => {
    for (final kind in NotificationKind.values)
      if (settings.get(Prefs.notify(kind))) kind,
  };

  /// The `enable` and `registration` answer; null when native code has none.
  static _Registration? _decodeRegistration(Object? json) {
    if (json == null) return null;
    if (json is Map) {
      final (platform, fid, key) = (json['platform'], json['fid'], json['key']);
      if (fid is String && key is String) {
        switch (platform) {
          case 'android':
            return (platform: PushPlatform.android, fid: fid, key: key);
          case 'ios':
            return (platform: PushPlatform.ios, fid: fid, key: key);
        }
      }
    }
    throw FormatException('push registration: $json');
  }

  @override
  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    _sessions.removeListener(_onSessions);
    _shell.removeListener(_syncVisible);
    _machines.removeListener(_follow);
    _settings.removeListener(_onSettings);
    WidgetsBinding.instance.removeObserver(this);
    for (final (_, subscription) in _statuses.values) {
      unawaited(subscription.cancel());
    }
    unawaited(_taps.close());
    unawaited(_failures.close());
    super.dispose();
  }
}
