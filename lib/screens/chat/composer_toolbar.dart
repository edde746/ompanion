import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../utils/token_count.dart';
import 'model_picker.dart';

/// The thinking level button: loads the model's levels when opened and marks the current one.
class ThinkingPicker extends StatefulWidget {
  const ThinkingPicker({super.key, required this.session, required this.level, required this.above});

  final LiveSession session;

  /// Null when the model reports none, which omp treats as off.
  final String? level;

  /// The composer block the menu opens above.
  final GlobalKey above;

  @override
  State<ThinkingPicker> createState() => _ThinkingPickerState();
}

/// The level omp reports for a model without thinking.
const _off = 'off';

class _ThinkingPickerState extends State<ThinkingPicker> {
  final _menu = MenuController();
  bool _loading = false;
  List<String> _levels = const [];
  Offset _offset = Offset.zero;

  Future<void> _open() async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _loading = true);
    final List<String> levels;
    try {
      levels = await widget.session.rpc.getAvailableThinkingLevels();
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.thinkingFailed(error: '$error'))));
      return;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
    if (!mounted) return;
    if (levels.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.noThinking)));
      return;
    }
    setState(() {
      _levels = levels;
      _offset = menuOffsetAbove(context, widget.above, alignStart: false);
    });
    _menu.open();
  }

  Future<void> _set(String level) async {
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.session.rpc.setThinkingLevel(level);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.thinkingFailed(error: '$error'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final current = widget.level ?? _off;
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: _offset,
      menuChildren: [
        for (final level in _levels)
          MenuItemButton(
            key: ValueKey('thinking-$level'),
            leadingIcon: SizedBox.square(
              dimension: 18,
              child: level == current ? Icon(Symbols.check, size: 18, color: scheme.onSurface) : null,
            ),
            onPressed: () => level == current ? null : unawaited(_set(level)),
            child: Text(level),
          ),
      ],
      builder: (context, controller, _) => ToolbarButton(
        key: const ValueKey('thinking-picker'),
        icon: Symbols.neurology,
        label: current,
        tooltip: t.chat.thinking(level: current),
        busy: _loading,
        onPressed: _loading ? null : () => controller.isOpen ? controller.close() : unawaited(_open()),
      ),
    );
  }
}

/// Context use of the session as a ring and a percentage; the tooltip adds tokens and cost.
class ContextMeter extends StatelessWidget {
  const ContextMeter({super.key, required this.usage, required this.cost});

  final ContextUsage? usage;
  final double cost;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final usage = this.usage;
    final fraction = usage == null ? 0.0 : (usage.percent / 100).clamp(0.0, 1.0);
    final color = fraction >= 0.9
        ? colors.error
        : fraction >= 0.7
        ? colors.warning
        : theme.colorScheme.onSurfaceVariant;
    final costText = '\$${cost.toStringAsFixed(cost < 1 ? 4 : 2)}';
    return Tooltip(
      message: usage == null
          ? t.chat.contextUnknown(cost: costText)
          : t.chat.contextTooltip(
              tokens: formatTokens(usage.tokens),
              window: formatTokens(usage.contextWindow),
              percent: usage.percent.toStringAsFixed(1),
              cost: costText,
            ),
      child: SizedBox(
        height: AppSizes.control,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSizes.gap),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(
                  value: fraction,
                  strokeWidth: 2.5,
                  color: color,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                usage == null ? '–' : '${usage.percent.round()}%',
                style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
