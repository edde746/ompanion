import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

import '../../../i18n/strings.g.dart';
import '../../../sessions/session_view_builder.dart';
import '../dock_empty_state.dart';

/// The session's todo phases (`todoPhases`), live: a checklist per phase with each task's status.
class TodosTab extends StatelessWidget {
  const TodosTab({super.key, required this.session});

  final LiveSession session;

  @override
  Widget build(BuildContext context) {
    return SessionViewSelector<List<TodoPhase>>(
      session: session,
      select: (view) => view.todoPhases,
      builder: (context, phases) {
        final t = context.t.dock.todo;
        if (phases.every((phase) => phase.tasks.isEmpty)) {
          return DockEmptyState(icon: Icons.checklist, message: t.empty);
        }
        return ListView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          children: [
            for (final phase in phases)
              if (phase.tasks.isNotEmpty) _PhaseSection(phase: phase),
          ],
        );
      },
    );
  }
}

class _PhaseSection extends StatelessWidget {
  const _PhaseSection({required this.phase});

  final TodoPhase phase;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final done = phase.tasks.where((task) => task.status == TodoStatus.completed).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  phase.name,
                  style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                context.t.dock.todo.progress(done: done, total: phase.tasks.length),
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
        for (final task in phase.tasks) _TaskTile(task: task),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task});

  final TodoTask task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.dock.todo;
    final (icon, color, label) = switch (task.status) {
      TodoStatus.pending => (Icons.radio_button_unchecked, scheme.outline, t.pending),
      TodoStatus.inProgress => (Icons.timelapse, scheme.primary, t.inProgress),
      TodoStatus.completed => (Icons.check_circle, scheme.tertiary, t.completed),
      TodoStatus.abandoned => (Icons.cancel_outlined, scheme.outline, t.abandoned),
      TodoStatus.blocked => (Icons.block, scheme.error, t.blocked),
    };
    final finished = task.status == TodoStatus.completed || task.status == TodoStatus.abandoned;
    final details = [
      if (task.blocker case final blocker? when blocker.isNotEmpty) t.blockedBy(reason: blocker),
      if (task.details case final details? when details.isNotEmpty) details,
      ...task.notes,
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Tooltip(
            message: label,
            child: Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 18, color: color)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  task.content,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: finished ? scheme.onSurfaceVariant : scheme.onSurface,
                    decoration: task.status == TodoStatus.abandoned ? TextDecoration.lineThrough : null,
                    fontWeight: task.status == TodoStatus.inProgress ? FontWeight.w600 : null,
                  ),
                ),
                for (final line in details)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      line,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: task.status == TodoStatus.blocked ? scheme.error : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
