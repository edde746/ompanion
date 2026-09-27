import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../sessions/session_view_builder.dart';
import '../../sessions/sessions_provider.dart';
import '../machines/connect_dialogs.dart';

/// The connection of [session] when it is not live: a progress line while connecting, the retry countdown
/// with "retry now" while reconnecting, and "reopen" once the link is closed for good.
class LinkBanner extends StatelessWidget {
  const LinkBanner({super.key, required this.session});

  final LiveSession session;

  @override
  Widget build(BuildContext context) {
    return LinkStateBuilder(
      session: session,
      builder: (context, state) => switch (state) {
        // Connecting shows in the header's state, where it moves nothing.
        LinkLive() || LinkConnecting() => const SizedBox.shrink(),
        LinkReconnecting() => _Reconnecting(session: session, state: state),
        LinkClosed() => _Closed(session: session, state: state),
      },
    );
  }
}

class _Reconnecting extends StatefulWidget {
  const _Reconnecting({required this.session, required this.state});

  final LiveSession session;
  final LinkReconnecting state;

  @override
  State<_Reconnecting> createState() => _ReconnectingState();
}

class _ReconnectingState extends State<_Reconnecting> {
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = widget.state;
    final left = state.nextTry.difference(DateTime.now());
    final seconds = left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
    final cause = state.cause;
    return _Banner(
      icon: Icons.sync_problem,
      color: AppColors.of(context).warning,
      text: t.chat.reconnecting(attempt: state.attempt, seconds: seconds),
      detail: cause == null ? null : describeConnectError(t, cause),
      actions: [TextButton(onPressed: widget.session.reconnectNow, child: Text(t.chat.retryNow))],
    );
  }
}

class _Closed extends StatefulWidget {
  const _Closed({required this.session, required this.state});

  final LiveSession session;
  final LinkClosed state;

  @override
  State<_Closed> createState() => _ClosedState();
}

class _ClosedState extends State<_Closed> {
  bool _reopening = false;

  Future<void> _reopen() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    final sessions = context.read<SessionsProvider>();
    setState(() => _reopening = true);
    try {
      await sessions.reopen(widget.session);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.reopenFailed(error: describeConnectError(t, error)))));
      if (mounted) setState(() => _reopening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final state = widget.state;
    final cause = state.cause;
    final exitCode = state.exitCode;
    return _Banner(
      icon: Icons.link_off,
      color: AppColors.of(context).error,
      text: exitCode == null ? t.chat.closed : t.chat.exited(code: exitCode),
      detail: cause == null ? null : describeConnectError(t, cause),
      actions: [
        TextButton(
          onPressed: () => unawaited(context.read<SessionsProvider>().detach(widget.session)),
          child: Text(t.common.close),
        ),
        FilledButton.tonal(onPressed: _reopening ? null : () => unawaited(_reopen()), child: Text(t.chat.reopen)),
      ],
    );
  }
}

/// A flat strip under the header; only the icon carries the state's colour.
class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.color, required this.text, required this.actions, this.detail});

  final IconData icon;
  final Color color;
  final String text;
  final String? detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final detail = this.detail;
    return ColoredBox(
      color: theme.colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(text, style: theme.textTheme.bodyMedium),
                  if (detail != null)
                    Text(
                      detail,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            for (final action in actions) ...[const SizedBox(width: AppSizes.gap), action],
          ],
        ),
      ),
    );
  }
}
