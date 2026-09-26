import 'package:flutter/material.dart';

import '../../sessions/message_mentions.dart';

/// [parts] of a user message as inline spans: text as it is, each mention a chip with the file's icon and name, its
/// path in a tooltip. [onOpen] opens a mentioned path on the machine; a `local://` mention, or any mention without
/// [onOpen], shows its tooltip on tap instead.
List<InlineSpan> mentionSpans(List<MessagePart> parts, {TextStyle? style, void Function(String path)? onOpen}) => [
  for (final part in parts)
    switch (part) {
      MessageText(:final source) => TextSpan(text: source, style: style),
      final MessageMention mention => WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: _MentionChip(mention, style: style, onOpen: mention.url ? null : onOpen),
      ),
    },
];

class _MentionChip extends StatelessWidget {
  const _MentionChip(this.mention, {required this.style, required this.onOpen});

  final MessageMention mention;
  final TextStyle? style;
  final void Function(String path)? onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final onOpen = this.onOpen;
    final icon = mention.folder
        ? Icons.folder_outlined
        : mention.url && mention.name.startsWith('paste-')
        ? Icons.notes
        : Icons.insert_drive_file_outlined;
    return Tooltip(
      message: mention.path,
      triggerMode: onOpen == null ? TooltipTriggerMode.tap : null,
      child: Material(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: onOpen == null ? null : () => onOpen(mention.path),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 14, color: scheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Flexible(
                  child: Text(mention.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
