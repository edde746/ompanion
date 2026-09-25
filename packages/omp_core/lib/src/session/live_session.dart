import 'dart:async';

import '../companion/companion_client.dart';
import '../rpc/rpc_client.dart';
import '../store/session_view.dart';

/// One open omp session as the UI sees it: a live view plus the clients to command it.
///
/// Created by `MachineRuntime.open` and `MachineRuntime.control`, which launch or attach the run, feed every
/// frame through the reducer, reconnect after link loss and resync the view. The UI never talks to transports
/// directly.
abstract interface class LiveSession {
  /// Identifies the run directory on the machine; stable across reconnects and devices. `control` for the
  /// machine's control session, which has no run directory.
  String get runId;

  /// Absolute session file path on the machine as omp reports it (`get_state.sessionFile`); omp writes the
  /// file with the first message. Null for the control session (`--no-session`). Follows session switches
  /// inside the run (`new_session`, `switch_session`, `branch`, fork, …).
  String? get sessionPath;

  /// Host-native working directory omp runs in (`--cwd`).
  String get cwd;

  /// Current view. Replaced, never mutated; compare with `identical`.
  SessionView get view;

  /// Emits every new [view]. Broadcast.
  Stream<SessionView> get views;

  LinkState get linkState;

  /// Emits every new [linkState]. Broadcast.
  Stream<LinkState> get linkStates;

  /// The RPC client of the current connection. After a reconnect this returns the new client, so
  /// read it at call time, never cache it. Calls while [linkState] is not [LinkLive] throw
  /// `RpcClosedException`.
  RpcClient get rpc;

  /// Companion client of the current connection; same lifetime rules as [rpc].
  CompanionClient get companion;

  /// The companion's `hello` from the first attach: its version, verbs and events. Null when the process has no
  /// companion; then every [companion] call would reach the model as a prompt, so never make one.
  CompanionHello? get companionHello;

  /// Closes request [id] in this device's view at once: after answering it here (every device also closes it
  /// when the answer reaches `in.jsonl`), or for one-shot requests (`EditorTextRequest`, `OpenUrlRequest`) and
  /// dialogs whose timeout passed.
  void dismissRequest(String id);

  /// Removes toast [seq] from the view.
  void dismissNotice(int seq);

  /// While [linkState] is [LinkReconnecting]: starts the next attempt now instead of at `nextTry`.
  void reconnectNow();

  /// Detaches this device. The omp process keeps running for other devices. The control session's process
  /// ends; the next `MachineRuntime.control` starts a new one.
  Future<void> detach();

  /// Stops the omp process gracefully (EOF on its stdin), then detaches.
  Future<void> stop();
}

sealed class LinkState {
  const LinkState();
}

final class LinkConnecting extends LinkState {
  const LinkConnecting();
}

final class LinkLive extends LinkState {
  const LinkLive();
}

/// The link dropped; the runtime is retrying. [attempt] starts at 1; [nextTry] is when the next attempt starts.
final class LinkReconnecting extends LinkState {
  const LinkReconnecting({required this.attempt, required this.nextTry, this.cause});

  final int attempt;
  final DateTime nextTry;
  final Object? cause;
}

/// Terminal: detached, stopped, the omp process exited, or reconnecting gave up (e.g. auth failed).
final class LinkClosed extends LinkState {
  const LinkClosed({this.cause, this.exitCode});

  final Object? cause;
  final int? exitCode;
}
