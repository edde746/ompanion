import 'package:flutter/material.dart';

/// Choice from a list: a flat filled button showing the current label and a chevron, opening a flat menu
/// that marks the current value with a leading check.
class AppSelect<T> extends StatelessWidget {
  const AppSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.tooltip,
    this.expand = false,
  });

  final T value;
  final List<(T value, String label)> options;
  final ValueChanged<T> onChanged;
  final String? tooltip;

  /// Fill the available width; the menu then matches the button's width.
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final label = options.where((o) => o.$1 == value).map((o) => o.$2).firstOrNull ?? '';
    Widget anchor(double? width) => MenuAnchor(
      style: width == null ? null : MenuStyle(minimumSize: WidgetStatePropertyAll(Size(width, 0))),
      menuChildren: [
        for (final (optionValue, optionLabel) in options)
          MenuItemButton(
            leadingIcon: SizedBox.square(
              dimension: 18,
              child: optionValue == value ? Icon(Icons.check, size: 18, color: scheme.onSurface) : null,
            ),
            onPressed: () => onChanged(optionValue),
            child: Text(optionLabel),
          ),
      ],
      builder: (context, controller, _) {
        final button = FilledButton.tonal(
          onPressed: () => controller.isOpen ? controller.close() : controller.open(),
          style: const ButtonStyle(
            padding: WidgetStatePropertyAll(EdgeInsetsDirectional.only(start: 12, end: 8)),
            alignment: AlignmentDirectional.centerStart,
          ),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              Flexible(
                fit: expand ? FlexFit.tight : FlexFit.loose,
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 4),
              Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
            ],
          ),
        );
        final sized = expand ? SizedBox(width: double.infinity, child: button) : button;
        return tooltip == null ? sized : Tooltip(message: tooltip, child: sized);
      },
    );
    if (!expand) return anchor(null);
    return LayoutBuilder(
      builder: (context, constraints) => anchor(constraints.hasBoundedWidth ? constraints.maxWidth : null),
    );
  }
}
