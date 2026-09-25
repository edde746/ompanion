import 'dart:async';

import '../companion/companion_client.dart';
import '../rpc/rpc_client.dart';
import '../store/session_view.dart';

/// One open omp session as the UI sees it: a live view plus the clients to command it.
///
/// Owned by `SessionRuntime` (lib/src/session/session_runtime.dart), which launches or attaches the
/// run, feeds every frame through the reducer, reconnects after link loss and resyncs the view.
/// The UI never talks to transports directly.
abstract interface class LiveSession {
  /// Identifies the run directory on the machine; stable across reconnects and devices.
  String get runId;

  /// Absolute session file path on the machine, or null for a session omp has not persisted yet.
  String? get sessionPath;

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

  /// Detaches this device. The omp process keeps running for other devices.
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
