import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../sessions/composer_attachments.dart';
import '../../utils/byte_size.dart';
import 'transcript/code_style.dart';
import 'transcript/images.dart';

/// The draft's attachments above the composer's text, in the order they came: image thumbnails that open the zoom
/// viewer, files and folders by name and size, pasted texts by line count, which open a preview. Every chip has a
/// remove button, and Tab reaches every chip that acts and every remove button.
class AttachmentChips extends StatelessWidget {
  const AttachmentChips({super.key, required this.attachments, required this.onRemove, required this.onInline});

  final List<ComposerAttachment> attachments;
  final ValueChanged<ComposerAttachment> onRemove;

  /// "Paste inline" in a pasted text's preview.
  final ValueChanged<TextAttachment> onInline;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Wrap(
        spacing: AppSizes.gap,
        runSpacing: AppSizes.gap,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final attachment in attachments)
            switch (attachment) {
              ImageAttachment() => _ImageChip(
                key: ObjectKey(attachment),
                attachment: attachment,
                onRemove: () => onRemove(attachment),
              ),
              FileAttachment() => _FileChip(
                key: ObjectKey(attachment),
                attachment: attachment,
                onRemove: () => onRemove(attachment),
              ),
              TextAttachment() => _TextChip(
                key: ObjectKey(attachment),
                attachment: attachment,
                onRemove: () => onRemove(attachment),
                onInline: () => onInline(attachment),
              ),
            },
        ],
      ),
    );
  }
}

class _ImageChip extends StatefulWidget {
  const _ImageChip({super.key, required this.attachment, required this.onRemove});

  final ImageAttachment attachment;
  final VoidCallback onRemove;

  @override
  State<_ImageChip> createState() => _ImageChipState();
}

class _ImageChipState extends State<_ImageChip> {
  late final Uint8List _bytes = base64Decode(widget.attachment.image.data);

  @override
  Widget build(BuildContext context) {
    final label = widget.attachment.name ?? context.t.composer.pastedImage;
    return Stack(
      children: [
        Tooltip(
          message: label,
          child: Material(
            clipBehavior: Clip.antiAlias,
            borderRadius: const BorderRadius.all(Radius.circular(8)),
            child: InkWell(
              onTap: () => unawaited(showDialog<void>(context: context, builder: (context) => ZoomedImage(_bytes))),
              child: Semantics(
                image: true,
                label: label,
                child: Image.memory(_bytes, width: 64, height: 64, fit: BoxFit.cover, gaplessPlayback: true),
              ),
            ),
          ),
        ),
        Positioned(top: 2, right: 2, child: _RemoveButton(onPressed: widget.onRemove, onImage: true)),
      ],
    );
  }
}

class _FileChip extends StatefulWidget {
  const _FileChip({super.key, required this.attachment, required this.onRemove});

  final FileAttachment attachment;
  final VoidCallback onRemove;

  @override
  State<_FileChip> createState() => _FileChipState();
}

class _FileChipState extends State<_FileChip> {
  // A folder is attached by path; it has no size of its own.
  late final bool _folder = switch (widget.attachment.path) {
    final path? => FileSystemEntity.isDirectorySync(path),
    null => false,
  };

  @override
  Widget build(BuildContext context) {
    final attachment = widget.attachment;
    return _Chip(
      tooltip: attachment.path ?? attachment.name,
      icon: _folder ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
      label: attachment.name,
      detail: _folder ? null : formatBytes(attachment.size),
      onRemove: widget.onRemove,
      muted: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

class _TextChip extends StatelessWidget {
  const _TextChip({super.key, required this.attachment, required this.onRemove, required this.onInline});

  final TextAttachment attachment;
  final VoidCallback onRemove;
  final VoidCallback onInline;

  Future<void> _preview(BuildContext context) async {
    final inline = await showDialog<bool>(context: context, builder: (_) => _PastedTextPreview(attachment));
    if (inline ?? false) onInline();
  }

  @override
  Widget build(BuildContext context) {
    return _Chip(
      icon: Icons.notes,
      label: context.t.composer.pastedText(n: attachment.lineCount),
      onTap: () => unawaited(_preview(context)),
      onRemove: onRemove,
      muted: Theme.of(context).colorScheme.onSurfaceVariant,
    );
  }
}

/// A file or text chip: one control tall, the chip tone, icon, label, an optional muted detail and the remove button.
class _Chip extends StatelessWidget {
  const _Chip({
    required this.icon,
    required this.label,
    required this.onRemove,
    required this.muted,
    this.detail,
    this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String label;
  final String? detail;
  final String? tooltip;
  final VoidCallback? onTap;
  final VoidCallback onRemove;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget chip = Material(
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: const BorderRadius.all(Radius.circular(AppSizes.radius)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: SizedBox(
          height: AppSizes.control,
          child: Padding(
            padding: const EdgeInsets.only(left: 10, right: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: muted),
                const SizedBox(width: AppSizes.gap),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 240),
                  child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                ),
                if (detail != null) ...[
                  const SizedBox(width: AppSizes.gap),
                  Text(detail!, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
                ],
                const SizedBox(width: 4),
                _RemoveButton(onPressed: onRemove),
              ],
            ),
          ),
        ),
      ),
    );
    if (tooltip != null) chip = Tooltip(message: tooltip, child: chip);
    return chip;
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton({required this.onPressed, this.onImage = false});

  final VoidCallback onPressed;

  /// Over a thumbnail: a filled disc that stands out from the picture.
  final bool onImage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconButton(
      style: IconButton.styleFrom(
        backgroundColor: onImage ? scheme.surfaceContainerHighest : null,
        foregroundColor: onImage ? scheme.onSurface : scheme.onSurfaceVariant,
        minimumSize: const Size.square(24),
        fixedSize: Size.square(onImage ? 24 : 28),
        padding: EdgeInsets.zero,
      ),
      visualDensity: VisualDensity.compact,
      iconSize: 14,
      tooltip: context.t.composer.remove,
      icon: const Icon(Icons.close),
      onPressed: onPressed,
    );
  }
}

/// A pasted text, read-only, with "Paste inline" to move it into the text field. Very long pastes show their start:
/// laying out megabytes of text at once would stall the window.
class _PastedTextPreview extends StatelessWidget {
  const _PastedTextPreview(this.attachment);

  static const _shown = 50000;

  final TextAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final t = context.t.composer;
    final theme = Theme.of(context);
    final text = attachment.text;
    final truncated = text.length > _shown;
    return AlertDialog(
      title: Text(t.pastedText(n: attachment.lineCount)),
      content: SizedBox(
        width: 720,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Flexible(
              child: Material(
                color: theme.colorScheme.surfaceContainerHigh,
                borderRadius: const BorderRadius.all(Radius.circular(AppSizes.radius)),
                clipBehavior: Clip.antiAlias,
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(truncated ? text.substring(0, _shown) : text, style: codeTextStyle(theme)),
                ),
              ),
            ),
            if (truncated)
              Padding(
                padding: const EdgeInsets.only(top: AppSizes.gap),
                child: Text(
                  t.previewTruncated(shown: _shown, total: text.length),
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t.common.close)),
        FilledButton.tonal(
          key: const ValueKey('paste-inline'),
          onPressed: () => Navigator.pop(context, true),
          child: Text(t.pasteInline),
        ),
      ],
    );
  }
}
