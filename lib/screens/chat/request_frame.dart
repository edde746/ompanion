import 'dart:async';

import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';

/// Title, scrollable body, error line and actions, laid out as a dialog or as a bottom sheet.
class RequestFrame extends StatelessWidget {
  const RequestFrame({
    super.key,
    required this.sheet,
    required this.title,
    required this.body,
    required this.actions,
    this.deadline,
    this.error,
  });

  final bool sheet;
  final String title;
  final Widget body;
  final List<Widget> actions;
  final DateTime? deadline;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deadline = this.deadline;
    final error = this.error;
    final content = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Flexible(child: SingleChildScrollView(child: body)),
        if (deadline != null) ...[const SizedBox(height: 12), Countdown(until: deadline)],
        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error, style: TextStyle(color: theme.colorScheme.error)),
        ],
      ],
    );
    if (!sheet) {
      return AlertDialog(
        title: Text(title),
        content: SizedBox(width: 560, child: content),
        actions: actions,
      );
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, 16 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleLarge),
          const SizedBox(height: 12),
          Flexible(child: content),
          const SizedBox(height: 16),
          OverflowBar(alignment: MainAxisAlignment.end, spacing: 8, overflowSpacing: 8, children: actions),
        ],
      ),
    );
  }
}

/// "12 s left", updated every second.
class Countdown extends StatefulWidget {
  const Countdown({super.key, required this.until});

  final DateTime until;

  @override
  State<Countdown> createState() => _CountdownState();
}

class _CountdownState extends State<Countdown> {
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
    final left = widget.until.difference(DateTime.now());
    final seconds = left.isNegative ? 0 : (left.inMilliseconds / 1000).ceil();
    return Text(
      context.t.requests.secondsLeft(n: seconds),
      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
    );
  }
}

