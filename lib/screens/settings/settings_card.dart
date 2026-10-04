import 'package:flutter/material.dart';

import '../../app/theme.dart';

/// A `surfaceContainer` block with `cardRadius`, the settings pane's grouping: a [Material] so the ink of the rows
/// inside it lands on the block's own tone.
class SettingsCard extends StatelessWidget {
  const SettingsCard({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    borderRadius: BorderRadius.circular(AppSizes.cardRadius),
    clipBehavior: Clip.antiAlias,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

/// A link in a [SettingsCard]: the label, an optional muted line under it, and a 16 px mark at the end.
/// A control tall with 4 px insets above and below its text, and taller when the label wraps or a detail line
/// takes the second line, so no label is ever cut. No start icon, no divider: the row is the whole target.
class SettingsLinkRow extends StatelessWidget {
  const SettingsLinkRow({super.key, required this.label, this.detail, required this.trailing, required this.onTap});

  final String label;
  final String? detail;
  final IconData trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: ConstrainedBox(
          // One control tall with the 4 px insets: a 20 px line box, or two of them.
          constraints: const BoxConstraints(minHeight: AppSizes.control - 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodyMedium),
                    if (detail case final detail?)
                      Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: AppSizes.gap),
              Icon(trailing, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// A setting that is on or off in a [SettingsCard]: the label, an optional muted line under it, and the switch at the
/// end.
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({super.key, required this.label, this.detail, required this.value, required this.onChanged});

  final String label;
  final String? detail;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 8, top: 4, bottom: 4),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: AppSizes.control),
        child: Row(
          children: [
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: theme.textTheme.bodyMedium),
                  if (detail case final detail?)
                    Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: AppSizes.gap),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}
