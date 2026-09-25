import 'dart:async';

import 'package:flutter/widgets.dart';
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
    final dialogs = dialogConnectPrompts(context);
    try {
      switch (prompt) {
        case PendingPassword(:final hop, :final answer):
          final password = await dialogs.password(hop);
          if (!answer.isCompleted) answer.complete(password);
        case PendingKeyboardInteractive(:final request, :final answer):
          final responses = await dialogs.keyboardInteractive(request);
          if (!answer.isCompleted) answer.complete(responses);
        case PendingHostKey(:final check, :final verdict, :final answer):
          final trusted = await dialogs.hostKey(check, verdict);
          if (!answer.isCompleted) answer.complete(trusted);
      }
    } finally {
      // A dialog that could not be shown fails its connection attempt rather than leaving it hanging.
      prompt.cancel();
      _queue.remove(prompt);
      _showing = null;
      _pump();
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
