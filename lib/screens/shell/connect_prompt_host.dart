import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../sessions/connect_prompt_queue.dart';
import '../../sessions/sessions_provider.dart';
import '../machines/connect_dialogs.dart';

/// Shows the connection prompts machine runtimes queue (passwords, keyboard-interactive, host keys), one at
/// a time and only while the app is in the foreground: a background reconnect waits for the user instead of
/// failing on a prompt nobody sees.
class ConnectPromptHost extends StatefulWidget {
  const ConnectPromptHost({super.key, required this.child});

  final Widget child;

  @override
  State<ConnectPromptHost> createState() => _ConnectPromptHostState();
}

class _ConnectPromptHostState extends State<ConnectPromptHost> with WidgetsBindingObserver {
  late final ConnectPromptQueue _queue;
  PendingPrompt? _showing;

  @override
  void initState() {
    super.initState();
    _queue = context.read<SessionsProvider>().prompts;
    _queue.addListener(_pump);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _pump());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) => _pump();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _queue.removeListener(_pump);
    super.dispose();
  }

  bool get _foreground => switch (WidgetsBinding.instance.lifecycleState) {
    null || AppLifecycleState.resumed || AppLifecycleState.inactive => true,
    AppLifecycleState.hidden || AppLifecycleState.paused || AppLifecycleState.detached => false,
  };

  void _pump() {
    if (_showing != null || !mounted || !_foreground) return;
    final prompt = _queue.next;
    if (prompt == null) return;
    _showing = prompt;
    unawaited(_show(prompt));
  }

  Future<void> _show(PendingPrompt prompt) async {
    try {
      switch (prompt) {
        case PendingPassword(:final hop, :final answer):
          final password = await _dialog<String>(prompt, PasswordDialog(hop: hop.label));
          if (!answer.isCompleted) answer.complete(password);
        case PendingKeyboardInteractive(:final request, :final answer):
          final responses = await _dialog<List<String>>(prompt, KeyboardInteractiveDialog(request));
          if (!answer.isCompleted) answer.complete(responses);
        case PendingHostKey(:final check, :final verdict, :final answer):
          // Dismissing is declining: the connection attempt fails instead of trusting an unchecked key.
          final trusted = await _dialog<bool>(prompt, HostKeyDialog(check: check, verdict: verdict));
          if (!answer.isCompleted) answer.complete(trusted ?? false);
      }
    } finally {
      // A dialog that could not be shown fails its connection attempt rather than leaving it hanging.
      prompt.cancel();
      _queue.remove(prompt);
      _showing = null;
      _pump();
    }
  }

  /// Shows [dialog] until it pops, or until [prompt] is cancelled elsewhere (its machine was deleted, or a retry asked
  /// the same question again), which closes it: an answer there would be dropped.
  Future<T?> _dialog<T>(PendingPrompt prompt, Widget dialog) {
    final navigator = Navigator.of(context, rootNavigator: true);
    final route = DialogRoute<T>(context: context, builder: (_) => dialog);
    unawaited(
      prompt.settled.then((_) {
        if (route.isActive) navigator.removeRoute(route);
      }),
    );
    return navigator.push(route);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
