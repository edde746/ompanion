import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../sessions/exec_runs.dart';
import '../../sessions/sessions_provider.dart';
import '../../widgets/activity_mark.dart';
import 'transcript/ansi.dart';
import 'transcript/code_style.dart';

/// Output of the composer's `!` and `$` runs while they stream, and their result until dismissed.
class ExecPanel extends StatelessWidget {
  const ExecPanel({super.key, required this.session});

  final LiveSession session;

  /// Finished runs kept on screen; older ones drop off.
  static const _kept = 3;

  @override
  Widget build(BuildContext context) {
    final runs = context.read<SessionsProvider>().execRunsOf(session);
    return ListenableBuilder(
      listenable: runs,
      builder: (context, _) {
        final all = runs.runs;
        final shown = all.length <= _kept ? all : all.sublist(all.length - _kept);
        if (shown.isEmpty) return const SizedBox.shrink();
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final run in shown)
              _ExecCard(run: run, onAbort: () => unawaited(runs.abort(session)), onDismiss: () => runs.dismiss(run)),
          ],
        );
      },
    );
  }
}

class _ExecCard extends StatelessWidget {
  const _ExecCard({required this.run, required this.onAbort, required this.onDismiss});

  final ExecRun run;
  final VoidCallback onAbort;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final prefix = switch (run.kind) {
      ExecutionKind.bash => run.excludeFromContext ? '!!' : '!',
      ExecutionKind.python => run.excludeFromContext ? r'$$' : r'$',
    };
    final error = run.error;
    final exitCode = run.exitCode;
    final status = run.running
        ? t.exec.running
        : error != null
        ? t.exec.failed(error: '$error')
        : run.cancelled
        ? t.exec.cancelled
        : t.exec.exited(code: exitCode ?? '?');
    final base = codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize);
    final output = run.output.trimRight();
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 2, 12, 2),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                if (run.running) const Padding(padding: EdgeInsets.only(right: 8), child: ActivityMark()),
                Expanded(
                  child: Text(
                    '$prefix${run.source}',
                    style: base.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  status,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: error != null || (exitCode != null && exitCode != 0)
                        ? AppColors.of(context).error
                        : theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (run.running)
                  IconButton(
                    tooltip: t.exec.abort,
                    icon: const Icon(Symbols.stop, size: 18, fill: 1),
                    onPressed: onAbort,
                  )
                else
                  IconButton(tooltip: t.common.close, icon: const Icon(Symbols.close, size: 18), onPressed: onDismiss),
              ],
            ),
            if (output.isNotEmpty)
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText.rich(ansiSpan(output, base: base, scheme: theme.colorScheme)),
                ),
              ),
            if (run.truncated) Text(t.exec.truncated, style: theme.textTheme.labelSmall),
          ],
        ),
      ),
    );
  }
}
