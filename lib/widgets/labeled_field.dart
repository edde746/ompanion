import 'package:flutter/material.dart';

import '../app/theme.dart';

/// A control with its label above it. Filled fields do not float their label inside the fill: at one control
/// height it would sit against the top edge.
class LabeledField extends StatelessWidget {
  const LabeledField({super.key, required this.label, required this.child, this.error});

  final String label;
  final Widget child;

  /// Shown under the control, for controls without an error line of their own.
  final String? error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      // As a dialog's whole content it must not stretch the dialog to the screen's height.
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 4),
        child,
        if (error case final error?)
          Padding(
            padding: const EdgeInsets.only(top: 4, left: 12),
            child: Text(error, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).error)),
          ),
      ],
    );
  }
}
