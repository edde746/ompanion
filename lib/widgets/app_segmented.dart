import 'package:flutter/material.dart';

import '../app/theme.dart';

/// Two to four exclusive options: a flat track where the selected segment is one tone lighter.
class AppSegmented<T> extends StatelessWidget {
  const AppSegmented({
    super.key,
    required this.value,
    required this.segments,
    required this.onChanged,
    this.disabled = const {},
  });

  final T value;
  final List<(T value, String label, IconData? icon)> segments;
  final ValueChanged<T> onChanged;

  /// Segments shown dimmed that cannot be chosen.
  final Set<T> disabled;

  static const double _inset = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final innerRadius = BorderRadius.circular(AppSizes.radius - _inset);
    return Container(
      height: AppSizes.control,
      padding: const EdgeInsets.all(_inset),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(AppSizes.radius),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        // The selected segment fills the track's height, inset by _inset on every side.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (segmentValue, label, icon) in segments)
            Builder(
              builder: (context) {
                final selected = segmentValue == value;
                final enabled = !disabled.contains(segmentValue);
                final foreground = !enabled
                    ? scheme.onSurface.withValues(alpha: 0.38)
                    : selected
                    ? scheme.onSurface
                    : scheme.onSurfaceVariant;
                return Semantics(
                  button: true,
                  selected: selected,
                  enabled: enabled,
                  inMutuallyExclusiveGroup: true,
                  child: Material(
                    color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
                    borderRadius: innerRadius,
                    child: InkWell(
                      borderRadius: innerRadius,
                      onTap: enabled && !selected ? () => onChanged(segmentValue) : null,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (icon != null) ...[
                              Icon(icon, size: 16, color: foreground),
                              if (label.isNotEmpty) const SizedBox(width: 6),
                            ],
                            if (label.isNotEmpty)
                              Text(label, style: theme.textTheme.labelLarge?.copyWith(color: foreground)),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
