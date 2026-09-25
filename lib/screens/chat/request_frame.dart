import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';

/// One inline request: title with the open-request count and navigation, a scrollable body, the countdown, an error
/// line and the actions. A flat block docked above the composer; it never covers anything.
class RequestFrame extends StatelessWidget {
  const RequestFrame({
    super.key,
    required this.title,
    required this.body,
    required this.actions,
    this.navigation,
    this.deadline,
    this.error,
  });

  final String title;
  final Widget body;
  final List<Widget> actions;

  /// The "2 of 3" count with previous and next, when more than one request is open.
  final Widget? navigation;
  final DateTime? deadline;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final deadline = this.deadline;
    final error = this.error;
    final navigation = this.navigation;
    // The transcript keeps at least half of the column; a long form scrolls inside the panel.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.5;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: const BorderRadius.all(Radius.circular(AppSizes.cardRadius)),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: AppSizes.control,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (deadline != null) ...[Countdown(until: deadline), const SizedBox(width: AppSizes.gap)],
                    ?navigation,
                  ],
                ),
              ),
              const SizedBox(height: 4),
              Flexible(
                child: SingleChildScrollView(padding: const EdgeInsets.only(right: 8), child: body),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error, style: theme.textTheme.bodySmall?.copyWith(color: colors.error)),
              ],
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Wrap(
                  alignment: WrapAlignment.end,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: AppSizes.gap,
                  runSpacing: AppSizes.gap,
                  children: actions,
                ),
              ),
            ],
          ),
        ),
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
