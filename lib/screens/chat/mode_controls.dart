import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omp_core/companion.dart' show CompanionException;
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../utils/compact_duration.dart';
import '../../utils/token_count.dart';
import '../../widgets/labeled_field.dart';
import 'model_picker.dart';
import 'transcript/code_style.dart';

/// Whether [session]'s companion has [verb]: a detached run can carry a companion older than this app.
bool offersVerb(LiveSession session, String verb) => session.companionHello?.verbs.contains(verb) ?? false;

const _goalVerbs = ['goal.pause', 'goal.resume', 'goal.budget', 'goal.drop'];
const _loopVerbs = ['loop.suspend', 'loop.disable'];

/// Whether the composer shows [goal]: while it is active, paused or budget-limited, as the TUI's footer does, and
/// while the companion can act on it.
bool showsGoal(LiveSession session, Goal? goal) => switch (goal?.status) {
  GoalStatus.active ||
  GoalStatus.paused ||
  GoalStatus.budgetLimited => _goalVerbs.any((verb) => offersVerb(session, verb)),
  _ => false,
};

/// Whether the composer shows [loop]: while it is on and the companion can act on it.
bool showsLoop(LiveSession session, LoopState? loop) =>
    loop != null && _loopVerbs.any((verb) => offersVerb(session, verb));

/// [status] in words, for the goal control and the `goal` tool's line.
String goalStatusLabel(BuildContext context, GoalStatus status) {
  final t = context.t.goal.status;
  return switch (status) {
    GoalStatus.active => t.active,
    GoalStatus.paused => t.paused,
    GoalStatus.budgetLimited => t.budgetLimited,
    GoalStatus.complete => t.complete,
    GoalStatus.dropped => t.dropped,
  };
}

/// Tokens used against the budget: `12.4K of 50K tokens (37.6K left)`, or `12.4K tokens, no budget`.
String goalUsage(BuildContext context, int used, int? budget) {
  final t = context.t.goal;
  return budget == null
      ? t.usageNoBudget(used: formatTokens(used))
      : t.usage(used: formatTokens(used), budget: formatTokens(budget), left: formatTokens(math.max(0, budget - used)));
}

/// Calls [verb]; a failure shows as a snack bar with the companion's own message. The messenger and [failed] are taken
/// before the call: the control may be gone by the reply, e.g. when the goal completed meanwhile.
Future<void> _call(
  BuildContext context,
  LiveSession session,
  String verb,
  Map<String, Object?> args,
  String Function({required Object error}) failed,
) async {
  final messenger = ScaffoldMessenger.of(context);
  try {
    await session.companion.call(verb, args);
  } on Object catch (error) {
    final reason = error is CompanionException ? error.message : '$error';
    messenger.showSnackBar(SnackBar(content: Text(failed(error: reason))));
  }
}

/// Widest a goal or loop menu gets; narrower where the composer is.
const double _menuWidth = 360;

/// [menuOffsetAbove] for a menu [width] wide that starts at [button], moved left as far as it takes to end by the
/// composer block's right edge.
Offset _menuOffset(BuildContext button, GlobalKey above, double width) {
  final start = (button.findRenderObject()! as RenderBox).localToGlobal(Offset.zero).dx;
  final block = above.currentContext!.findRenderObject()! as RenderBox;
  final end = block.localToGlobal(Offset(block.size.width, 0)).dx;
  return menuOffsetAbove(button, above, alignStart: false).translate(-math.max(0.0, start + width - end), 0);
}

/// [ToolbarButton.color] of a held state: a paused or budget-limited goal, a suspended loop.
Color? _heldColor(BuildContext context, bool held) => held ? AppColors.of(context).warning : null;

/// [text] with no-break spaces, so a line breaks around it rather than inside it.
String _unbroken(String text) => text.replaceAll(' ', '\u00a0');

/// The goal's toolbar control: its tokens against the budget, as the TUI's footer shows them, and a menu with the
/// objective and its usage over pause or resume, the budget and drop.
class GoalControl extends StatefulWidget {
  const GoalControl({super.key, required this.session, required this.goal, required this.above});

  final LiveSession session;
  final Goal goal;

  /// The composer block the menu opens above.
  final GlobalKey above;

  @override
  State<GoalControl> createState() => _GoalControlState();
}

class _GoalControlState extends State<GoalControl> {
  final _menu = MenuController();
  Offset _offset = Offset.zero;
  double _width = _menuWidth;

  void _toggle() {
    if (_menu.isOpen) return _menu.close();
    setState(() {
      _width = math.min(_menuWidth, widget.above.currentContext!.size!.width);
      _offset = _menuOffset(context, widget.above, _width);
    });
    _menu.open();
  }

  Future<void> _goalCall(String verb, Map<String, Object?> args) =>
      _call(context, widget.session, verb, args, context.t.goal.failed);

  Future<void> _drop() async {
    final t = context.t;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.goal.dropTitle),
        content: Text(t.goal.dropBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          FilledButton(
            key: const ValueKey('goal-drop-confirm'),
            onPressed: () => Navigator.pop(context, true),
            child: Text(t.goal.dropConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _goalCall('goal.drop', const {});
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.goal;
    final theme = Theme.of(context);
    final goal = widget.goal;
    final session = widget.session;
    final used = formatTokens(goal.tokensUsed);
    final budget = goal.tokenBudget;
    final paused = goal.status == GoalStatus.paused;
    final status = goalStatusLabel(context, goal.status);
    final usage = goalUsage(context, goal.tokensUsed, budget);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: _offset,
      menuChildren: [
        _MenuHeader(
          width: _width,
          text: goal.objective,
          facts: [
            // Each fact stays whole: the line breaks only between them.
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: _unbroken(status),
                    style: TextStyle(color: _heldColor(context, goal.status != GoalStatus.active)),
                  ),
                  TextSpan(text: '  ·  ${_unbroken(usage)}'),
                  if (goal.timeUsedSeconds > 0)
                    TextSpan(
                      text:
                          '  ·  ${_unbroken(t.spent(time: compactDuration(Duration(seconds: goal.timeUsedSeconds))))}',
                    ),
                ],
              ),
              style: muted,
            ),
          ],
        ),
        if (paused && offersVerb(session, 'goal.resume'))
          MenuItemButton(
            key: const ValueKey('goal-resume'),
            leadingIcon: const Icon(Icons.play_arrow, size: 18),
            onPressed: () => unawaited(_goalCall('goal.resume', const {})),
            child: Text(t.resume),
          )
        else if (!paused && offersVerb(session, 'goal.pause'))
          MenuItemButton(
            key: const ValueKey('goal-pause'),
            leadingIcon: const Icon(Icons.pause, size: 18),
            onPressed: () => unawaited(_goalCall('goal.pause', const {})),
            child: Text(t.pause),
          ),
        // omp adjusts the budget of a running goal only; a paused one is resumed first.
        if (!paused && offersVerb(session, 'goal.budget'))
          _BudgetField(
            width: _width,
            budget: budget,
            onSet: (tokens) {
              _menu.close();
              unawaited(_goalCall('goal.budget', {'tokenBudget': tokens}));
            },
          ),
        if (offersVerb(session, 'goal.drop'))
          MenuItemButton(
            key: const ValueKey('goal-drop'),
            leadingIcon: const Icon(Icons.close, size: 18),
            onPressed: () => unawaited(_drop()),
            child: Text(t.drop),
          ),
      ],
      builder: (context, controller, _) => ToolbarButton(
        key: const ValueKey('goal-control'),
        icon: switch (goal.status) {
          GoalStatus.paused => Icons.pause,
          GoalStatus.budgetLimited => Icons.warning_amber_rounded,
          _ => Icons.flag_outlined,
        },
        color: _heldColor(context, goal.status != GoalStatus.active),
        label: t.label(usage: budget == null ? used : '$used/${formatTokens(budget)}'),
        tooltip: t.tooltip(status: status, usage: usage),
        onPressed: _toggle,
      ),
    );
  }
}

/// The goal's token budget, typed in the menu: a number, or `off` for none. Enter sets it; empty leaves it as it is,
/// as the TUI's budget editor does.
class _BudgetField extends StatefulWidget {
  const _BudgetField({required this.width, required this.budget, required this.onSet});

  final double width;
  final int? budget;
  final ValueChanged<int?> onSet;

  @override
  State<_BudgetField> createState() => _BudgetFieldState();
}

class _BudgetFieldState extends State<_BudgetField> {
  late final _text = TextEditingController(text: widget.budget?.toString() ?? '');
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _text.text.trim();
    if (value.isEmpty) return;
    if (value.toLowerCase() == 'off') return widget.onSet(null);
    final tokens = int.tryParse(value);
    if (tokens == null || tokens <= 0) return setState(() => _error = context.t.goal.budgetInvalid);
    widget.onSet(tokens);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.goal;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: widget.width,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        // Inside the popover, tones step up from the popover's own (docs/design.md), as in the model list.
        child: Theme(
          data: theme.copyWith(
            inputDecorationTheme: theme.inputDecorationTheme.copyWith(
              fillColor: WidgetStateColor.resolveWith(
                (states) => scheme.onSurface.withValues(alpha: states.contains(WidgetState.focused) ? 0.08 : 0.06),
              ),
            ),
          ),
          child: LabeledField(
            label: t.budget,
            error: _error,
            child: TextField(
              key: const ValueKey('goal-budget'),
              controller: _text,
              style: theme.textTheme.bodyMedium,
              textInputAction: TextInputAction.done,
              decoration: InputDecoration(
                hintText: t.budgetHint,
                suffixIcon: IconButton(
                  tooltip: t.setBudget,
                  icon: const Icon(Icons.check, size: 18),
                  onPressed: _submit,
                ),
              ),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
              onSubmitted: (_) => _submit(),
            ),
          ),
        ),
      ),
    );
  }
}

/// The loop's toolbar control: its state as the TUI's footer shows it (iterations left, time left, or the state
/// word), the condition in the tooltip, and a menu with its settings over suspend and turn off.
class LoopControl extends StatefulWidget {
  const LoopControl({super.key, required this.session, required this.loop, required this.above});

  final LiveSession session;
  final LoopState loop;

  /// The composer block the menu opens above.
  final GlobalKey above;

  @override
  State<LoopControl> createState() => _LoopControlState();
}

class _LoopControlState extends State<LoopControl> {
  final _menu = MenuController();
  Offset _offset = Offset.zero;
  double _width = _menuWidth;

  void _toggle() {
    if (_menu.isOpen) return _menu.close();
    setState(() {
      _width = math.min(_menuWidth, widget.above.currentContext!.size!.width);
      _offset = _menuOffset(context, widget.above, _width);
    });
    _menu.open();
  }

  /// Ticks once a second while the loop has a time limit, so the time left counts down.
  Timer? _clock;

  @override
  void initState() {
    super.initState();
    _startClock();
  }

  @override
  void didUpdateWidget(LoopControl oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((oldWidget.loop.limit is LoopDuration) != (widget.loop.limit is LoopDuration)) _startClock();
  }

  @override
  void dispose() {
    _clock?.cancel();
    super.dispose();
  }

  void _startClock() {
    _clock?.cancel();
    _clock = widget.loop.limit is LoopDuration
        ? Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}))
        : null;
  }

  Future<void> _loopCall(String verb) => _call(context, widget.session, verb, const {}, context.t.loop.failed);

  @override
  Widget build(BuildContext context) {
    final t = context.t.loop;
    final theme = Theme.of(context);
    final loop = widget.loop;
    final session = widget.session;
    final phase = loop.phase;
    final left = switch (loop.limit) {
      LoopDuration(:final deadline) => Duration(milliseconds: deadline - DateTime.now().millisecondsSinceEpoch),
      _ => null,
    };
    final label = switch ((phase, loop.limit)) {
      (LoopPhase.paused, _) => t.paused,
      (LoopPhase.waiting, _) => t.waiting,
      (LoopPhase.running, LoopIterations(:final remaining, :final total)) => t.iterations(
        remaining: remaining,
        total: total,
      ),
      (LoopPhase.running, LoopDuration()) => t.timeLeft(time: compactDuration(left!)),
      (LoopPhase.running, null) => t.running,
    };
    final condition = switch (loop.condition) {
      LoopCondition(until: true, :final command) => t.untilCondition(command: command),
      LoopCondition(until: false, :final command) => t.whileCondition(command: command),
      null => null,
    };
    final limit = switch (loop.limit) {
      LoopIterations(:final remaining, :final total) => t.iterationsLeft(remaining: remaining, total: total),
      LoopDuration(:final duration) => t.timeLeftOf(time: compactDuration(left!), total: compactDuration(duration)),
      null => null,
    };
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: _offset,
      menuChildren: [
        _MenuHeader(
          width: _width,
          text: loop.prompt ?? (phase == LoopPhase.paused ? t.pausedPrompt : t.waitingPrompt),
          quiet: loop.prompt == null,
          facts: [
            if (limit != null) Text(limit, style: muted),
            if (loop.condition case LoopCondition(:final until, :final command)) ...[
              Text(until ? t.untilLabel : t.whileLabel, style: muted),
              Text(command, style: codeTextStyle(theme).copyWith(color: muted?.color)),
            ],
            if (loop.iterations > 0) Text(t.done(n: loop.iterations), style: muted),
          ],
        ),
        if (phase == LoopPhase.running && offersVerb(session, 'loop.suspend'))
          MenuItemButton(
            key: const ValueKey('loop-suspend'),
            leadingIcon: const Icon(Icons.pause, size: 18),
            onPressed: () => unawaited(_loopCall('loop.suspend')),
            child: Text(t.suspend),
          ),
        if (offersVerb(session, 'loop.disable'))
          MenuItemButton(
            key: const ValueKey('loop-disable'),
            leadingIcon: const Icon(Icons.stop, size: 18),
            onPressed: () => unawaited(_loopCall('loop.disable')),
            child: Text(t.disable),
          ),
      ],
      builder: (context, controller, _) => ToolbarButton(
        key: const ValueKey('loop-control'),
        icon: phase == LoopPhase.paused ? Icons.pause : Icons.repeat,
        color: _heldColor(context, phase == LoopPhase.paused),
        label: label,
        tooltip: [label, ?limit, ?condition].join('  ·  '),
        onPressed: _toggle,
      ),
    );
  }
}

/// The top of a goal or loop menu: the objective or the loop's prompt, then its facts. Long texts scroll.
class _MenuHeader extends StatelessWidget {
  const _MenuHeader({required this.width, required this.text, required this.facts, this.quiet = false});

  final double width;
  final String text;
  final List<Widget> facts;

  /// [text] says what the loop waits for rather than quoting a prompt.
  final bool quiet;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodyMedium;
    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 160),
              // The menu scrolls itself with the primary controller; one controller cannot drive both.
              child: SingleChildScrollView(
                primary: false,
                child: Text(text, style: quiet ? style?.copyWith(color: theme.colorScheme.onSurfaceVariant) : style),
              ),
            ),
            for (final fact in facts) ...[const SizedBox(height: 4), fact],
          ],
        ),
      ),
    );
  }
}
