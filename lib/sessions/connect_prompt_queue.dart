import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:omp_core/ssh.dart';

import '../models/host_key_trust.dart';
import '../models/machine.dart';
import '../services/machine_connector.dart';

/// A question a connection attempt waits on. Completing [answer] resumes the attempt.
sealed class PendingPrompt {
  PendingPrompt(this.machine);

  final Machine machine;

  bool get answered;

  /// Completes once the prompt is answered or cancelled.
  Future<void> get settled;

  /// Gives up on the prompt: the connection attempt fails as if the user dismissed it.
  void cancel();
}

final class PendingPassword extends PendingPrompt {
  PendingPassword(super.machine, this.hop);

  final SshEndpoint hop;
  final Completer<String?> answer = Completer();

  @override
  bool get answered => answer.isCompleted;

  @override
  Future<void> get settled => answer.future;

  @override
  void cancel() {
    if (!answer.isCompleted) answer.complete(null);
  }
}

final class PendingKeyboardInteractive extends PendingPrompt {
  PendingKeyboardInteractive(super.machine, this.request);

  final KeyboardInteractiveRequest request;
  final Completer<List<String>?> answer = Completer();

  @override
  bool get answered => answer.isCompleted;

  @override
  Future<void> get settled => answer.future;

  @override
  void cancel() {
    if (!answer.isCompleted) answer.complete(null);
  }
}

final class PendingHostKey extends PendingPrompt {
  PendingHostKey(super.machine, this.check, this.verdict);

  final HostKeyCheck check;
  final HostKeyVerdict verdict;
  final Completer<bool> answer = Completer();

  @override
  bool get answered => answer.isCompleted;

  @override
  Future<void> get settled => answer.future;

  @override
  void cancel() {
    if (!answer.isCompleted) answer.complete(false);
  }
}

final class PendingPassphrase extends PendingPrompt {
  PendingPassphrase(super.machine, this.request);

  final KeyPassphraseRequest request;
  final Completer<({String passphrase, bool remember})?> answer = Completer();

  @override
  bool get answered => answer.isCompleted;

  @override
  Future<void> get settled => answer.future;

  @override
  void cancel() {
    if (!answer.isCompleted) answer.complete(null);
  }
}

/// Connection prompts of every machine runtime, from foreground connects and background reconnects
/// alike. A reconnect can need a password or a host-key decision while the app is in the background or
/// the user is looking at another machine, so prompts wait here, oldest first, until the prompt host
/// shows them one at a time while the app is in the foreground.
class ConnectPromptQueue extends ChangeNotifier {
  final List<PendingPrompt> _pending = [];

  /// The prompt to show next, or null.
  PendingPrompt? get next => _pending.firstOrNull;

  /// Prompts for connections to [machine] that queue here.
  ConnectPrompts promptsFor(Machine machine) => ConnectPrompts(
    password: (hop) => _enqueue(PendingPassword(machine, hop)).answer.future,
    keyboardInteractive: (request) => _enqueue(PendingKeyboardInteractive(machine, request)).answer.future,
    hostKey: (check, verdict) => _enqueue(PendingHostKey(machine, check, verdict)).answer.future,
    passphrase: (request) => _enqueue(PendingPassphrase(machine, request)).answer.future,
  );

  /// Removes [prompt] once the host completed it.
  void remove(PendingPrompt prompt) {
    if (_pending.remove(prompt)) notifyListeners();
  }

  /// Cancels every prompt of [machineId], e.g. when the machine was deleted.
  void cancelFor(String machineId) {
    final dropped = [
      for (final prompt in _pending)
        if (prompt.machine.id == machineId) prompt,
    ];
    if (dropped.isEmpty) return;
    for (final prompt in dropped) {
      prompt.cancel();
      _pending.remove(prompt);
    }
    notifyListeners();
  }

  T _enqueue<T extends PendingPrompt>(T prompt) {
    // A retrying reconnect asks again for the same hop; the attempt that asked first has given up by
    // then, so its prompt is dropped rather than shown twice.
    final stale = [
      for (final pending in _pending)
        if (_sameQuestion(pending, prompt)) pending,
    ];
    for (final old in stale) {
      old.cancel();
      _pending.remove(old);
    }
    _pending.add(prompt);
    notifyListeners();
    return prompt;
  }

  static bool _sameQuestion(PendingPrompt a, PendingPrompt b) => switch ((a, b)) {
    (PendingPassword(hop: final x), PendingPassword(hop: final y)) => a.machine.id == b.machine.id && x.id == y.id,
    (PendingKeyboardInteractive(), PendingKeyboardInteractive()) => a.machine.id == b.machine.id,
    (PendingHostKey(check: final x), PendingHostKey(check: final y)) =>
      a.machine.id == b.machine.id && x.host == y.host && x.port == y.port,
    (PendingPassphrase(request: final x), PendingPassphrase(request: final y)) =>
      a.machine.id == b.machine.id && x.hop == y.hop && x.path == y.path,
    _ => false,
  };
}
