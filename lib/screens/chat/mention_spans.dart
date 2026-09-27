import 'package:flutter/material.dart';

import '../../i18n/strings.g.dart';
import '../../sessions/message_mentions.dart';

/// [parts] of a user message as inline spans: text as it is, each file mention a chip with the file's icon and name,
/// its path in a tooltip, each tagged model a chip with its name, its pseudonym in a tooltip. [onOpen] opens a
/// mentioned path on the machine; a `local://` mention, or any mention without [onOpen], shows its tooltip on tap
/// instead.
List<InlineSpan> mentionSpans(List<MessagePart> parts, {TextStyle? style, void Function(String path)? onOpen}) => [
  for (final part in parts)
    switch (part) {
      MessageText(:final source) => TextSpan(text: source, style: style),
      final MessageMention mention => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _Chip(
          icon: mention.folder
              ? Icons.folder_outlined
              : mention.url && mention.name.startsWith('paste-')
              ? Icons.notes
              : Icons.insert_drive_file_outlined,
          label: mention.name,
          tooltip: mention.path,
          style: style,
          onTap: mention.url || onOpen == null ? null : () => onOpen(mention.path),
        ),
      ),
      MessageModel(:final name, :final agent) => modelChipSpan(name, style: style, agent: agent),
    },
];

/// A tagged model as an inline chip: the model icon and [name]. [agent], the pseudonym omp gave the model, goes in the
/// tooltip.
InlineSpan modelChipSpan(String name, {TextStyle? style, String? agent}) => WidgetSpan(
  alignment: PlaceholderAlignment.middle,
  child: Builder(
    builder: (context) => _Chip(
      icon: Icons.auto_awesome_outlined,
      label: name,
      tooltip: agent == null ? null : context.t.chat.modelAgent(agent: agent),
      style: style,
      onTap: null,
    ),
  ),
);

class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.tooltip,
    required this.style,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final TextStyle? style;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onTap = this.onTap;
    final chip = Material(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: scheme.onSurfaceVariant),
              const SizedBox(width: 4),
              Flexible(
                child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
              ),
            ],
          ),
        ),
      ),
    );
    final tooltip = this.tooltip;
    if (tooltip == null) return chip;
    return Tooltip(message: tooltip, triggerMode: onTap == null ? TooltipTriggerMode.tap : null, child: chip);
  }
}
