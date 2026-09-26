import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/store.dart';

import '../../../app/theme.dart';
import '../../../i18n/strings.g.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/byte_size.dart';
import 'transcript_actions.dart';

final _bytes = Expando<Uint8List>();
final _sizes = Expando<Size>();
final _byteSizes = Expando<Size>();

/// The decoded bytes of [image], decoded once per block.
Uint8List imageBytes(ImageBlock image) => _bytes[image] ??= base64Decode(image.data);

/// The pixel size stored in the header of [image] (PNG, JPEG, GIF, WebP), or null. Read before decoding so a
/// thumbnail takes its final height at once and the transcript does not shift when the picture arrives.
Size? imageSize(ImageBlock image) {
  final cached = _sizes[image];
  if (cached != null) return cached;
  final size = sniffImageSize(imageBytes(image));
  if (size != null) _sizes[image] = size;
  return size;
}

/// [sniffImageSize] of [bytes], read once per list.
Size? _bytesSize(Uint8List bytes) {
  final cached = _byteSizes[bytes];
  if (cached != null) return cached;
  final size = sniffImageSize(bytes);
  if (size != null) _byteSizes[bytes] = size;
  return size;
}

/// Width and height from an image file header (PNG, GIF, WebP, JPEG, BMP).
Size? sniffImageSize(Uint8List b) {
  int be16(int i) => b[i] << 8 | b[i + 1];
  int le16(int i) => b[i] | b[i + 1] << 8;
  int be32(int i) => b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];
  int le32(int i) => (b[i] | b[i + 1] << 8 | b[i + 2] << 16 | b[i + 3] << 24).toSigned(32);
  if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) {
    return Size(be32(16).toDouble(), be32(20).toDouble());
  }
  if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return Size(le16(6).toDouble(), le16(8).toDouble());
  }
  // A bottom-up BMP stores a negative height.
  if (b.length >= 26 && b[0] == 0x42 && b[1] == 0x4d) return Size(le32(18).toDouble(), le32(22).abs().toDouble());
  if (b.length >= 30 && b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 && b[8] == 0x57) {
    final chunk = String.fromCharCodes(b.sublist(12, 16));
    if (chunk == 'VP8 ') return Size((le16(26) & 0x3fff).toDouble(), (le16(28) & 0x3fff).toDouble());
    if (chunk == 'VP8L') {
      final bits = b[21] | b[22] << 8 | b[23] << 16 | b[24] << 24;
      return Size(((bits & 0x3fff) + 1).toDouble(), (((bits >> 14) & 0x3fff) + 1).toDouble());
    }
    if (chunk == 'VP8X') {
      return Size(
        ((b[24] | b[25] << 8 | b[26] << 16) + 1).toDouble(),
        ((b[27] | b[28] << 8 | b[29] << 16) + 1).toDouble(),
      );
    }
    return null;
  }
  if (b.length >= 4 && b[0] == 0xff && b[1] == 0xd8) {
    var i = 2;
    while (i + 9 < b.length) {
      if (b[i] != 0xff) return null;
      final marker = b[i + 1];
      // Start-of-frame markers carry the size; DHT (C4), JPG (C8) and DAC (CC) share the range but do not.
      if (marker >= 0xc0 && marker <= 0xcf && marker != 0xc4 && marker != 0xc8 && marker != 0xcc) {
        return Size(be16(i + 7).toDouble(), be16(i + 5).toDouble());
      }
      i += 2 + be16(i + 2);
    }
  }
  return null;
}

/// A thumbnail of [image] at most [maxHeight] tall, sized from its header before it decodes; tapping it opens a
/// zoomable view.
class TranscriptImage extends StatelessWidget {
  const TranscriptImage(this.image, {super.key, this.maxHeight = 240, this.maxWidth = 480});

  final ImageBlock image;
  final double maxHeight;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final size = imageSize(image);
    var width = maxWidth, height = maxHeight;
    if (size != null && size.width > 0 && size.height > 0) {
      final scale = [maxWidth / size.width, maxHeight / size.height, 1.0].reduce((a, b) => a < b ? a : b);
      width = size.width * scale;
      height = size.height * scale;
    }
    return Semantics(
      image: true,
      label: context.t.transcript.image,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showDialog<void>(context: context, builder: (context) => ZoomedImage(imageBytes(image))),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: width,
            height: height,
            child: Image.memory(
              imageBytes(image),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (context, error, stack) => ColoredBox(
                color: AppColors.of(context).errorSurface,
                child: Center(child: Icon(Icons.broken_image_outlined, color: AppColors.of(context).error)),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// [bytes] in a dialog as large as the window allows, zoomable; the viewer for images in the chat and the composer.
class ZoomedImage extends StatelessWidget {
  const ZoomedImage(this.bytes, {super.key});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          InteractiveViewer(maxScale: 8, child: Center(child: Image.memory(bytes))),
          Positioned(
            top: 4,
            right: 4,
            child: IconButton.filledTonal(
              tooltip: context.t.common.close,
              onPressed: () => Navigator.of(context).pop(),
              icon: const Icon(Icons.close),
            ),
          ),
        ],
      ),
    );
  }
}

/// [images] as a wrapping row of thumbnails.
class ImageStrip extends StatelessWidget {
  const ImageStrip(this.images, {super.key});

  final List<ImageBlock> images;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 8, runSpacing: 8, children: [for (final image in images) TranscriptImage(image)]);
}

/// Image [bytes] as wide as the space it gets and at most [maxHeight] tall, never larger than its own pixels, sized
/// from its header before it decodes; tapping it opens a zoomable view. Only the zoomed view decodes more than 1600
/// pixels across.
class FittedImage extends StatelessWidget {
  const FittedImage(this.bytes, {super.key, this.maxHeight = 360});

  final Uint8List bytes;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final size = _bytesSize(bytes);
    final known = size != null && size.width > 0 && size.height > 0;
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: known ? size.width : double.infinity,
          maxHeight: known ? math.min(size.height, maxHeight) : maxHeight,
        ),
        child: AspectRatio(
          aspectRatio: known ? size.width / size.height : 16 / 9,
          child: Semantics(
            image: true,
            label: context.t.transcript.image,
            child: InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => showDialog<void>(context: context, builder: (context) => ZoomedImage(bytes)),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.memory(
                  bytes,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                  cacheWidth: known && size.width > 1600 ? 1600 : null,
                  errorBuilder: (context, error, stack) => ColoredBox(
                    color: AppColors.of(context).errorSurface,
                    child: Center(child: Icon(Icons.broken_image_outlined, color: AppColors.of(context).error)),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// An image file of the session's machine, named by [path] (host-native, `~/…` or relative to the session's
/// directory). It loads on its own: it comes from the user's own machine over the session's link and cannot reach the
/// network. A placeholder shows while it loads, then the image with its name and an "Open in Files" action ([caption]),
/// or a notice of what is wrong; a file too large to send on its own offers its original. Without a machine to load
/// from (no [TranscriptActions.images]) the path shows as text.
class MachineImage extends StatefulWidget {
  const MachineImage({super.key, required this.path, this.caption = true});

  final String path;
  final bool caption;

  @override
  State<MachineImage> createState() => _MachineImageState();
}

class _MachineImageState extends State<MachineImage> {
  HostImage? _image;
  Object? _error;
  var _loadingOriginal = false;

  // Read once: TranscriptScope does not notify, and the screen passes new actions on every build.
  late final _images = context.getInheritedWidgetOfExactType<TranscriptScope>()?.actions.images;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void didUpdateWidget(MachineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path == widget.path) return;
    _image = null;
    _error = null;
    _start();
  }

  void _start() {
    _image = _images?.peek(widget.path);
    if (_images != null) unawaited(_load(original: false));
  }

  Future<void> _load({required bool original}) async {
    final path = widget.path;
    try {
      final image = await _images!.load(path, original: original);
      if (!mounted || path != widget.path) return;
      setState(() {
        _image = image;
        _error = null;
        _loadingOriginal = false;
      });
    } on Object catch (error) {
      appLogger.w('loading the image $path failed: $error');
      if (!mounted || path != widget.path) return;
      setState(() {
        _error = error;
        _loadingOriginal = false;
      });
    }
  }

  void _loadOriginal() {
    setState(() => _loadingOriginal = true);
    unawaited(_load(original: true));
  }

  @override
  Widget build(BuildContext context) {
    if (_images == null) return Text(widget.path);
    final t = context.t.transcript;
    final path = widget.path;
    return switch (_image) {
      final HostImageBytes image => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [FittedImage(image.bytes), if (widget.caption) _caption(context, image)],
      ),
      HostImageProblem(:final issue, :final size, :final canLoadOriginal) => _ImageNotice(
        icon: switch (issue) {
          HostImageIssue.denied => Icons.lock_outline,
          HostImageIssue.tooLarge => Icons.photo_size_select_large_outlined,
          _ => Icons.broken_image_outlined,
        },
        text: switch (issue) {
          HostImageIssue.missing => t.imageMissing(path: path),
          HostImageIssue.notFile => t.imageNotFile(path: path),
          HostImageIssue.denied => t.imageDenied(path: path),
          HostImageIssue.notImage => t.imageNotImage(path: path),
          HostImageIssue.unsupported => t.imageUnsupported(path: path, size: formatBytes(size ?? 0)),
          HostImageIssue.tooLarge => t.imageTooLarge(path: path, size: formatBytes(size ?? 0)),
        },
        action: canLoadOriginal
            ? (_loadingOriginal
                  ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : TextButton(
                      onPressed: _loadOriginal,
                      child: Text(t.loadOriginal(size: formatBytes(size!))),
                    ))
            : null,
      ),
      null when _error != null => _ImageNotice(
        icon: Icons.error_outline,
        text: t.imageFailed(path: path, error: '$_error'),
        action: TextButton(
          onPressed: () => setState(() {
            _error = null;
            _start();
          }),
          child: Text(t.retryImage),
        ),
      ),
      null => _ImageNotice(
        icon: Icons.image_outlined,
        text: t.imageLoading(name: _name(path)),
        action: const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
      ),
    };
  }

  Widget _caption(BuildContext context, HostImageBytes image) {
    final theme = Theme.of(context);
    final t = context.t.transcript;
    final dim = theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final facts = [
      _name(widget.path),
      if (image.width != null && image.height != null) '${image.width}×${image.height}',
      if (image.preview) t.imagePreview(sent: formatBytes(image.bytes.length), size: formatBytes(image.size)),
    ];
    // A Wrap puts the action under the facts where the width runs out (phones).
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 4,
      children: [
        Text(facts.join(' · '), style: dim),
        TextButton.icon(
          onPressed: () => TranscriptScope.of(context).onOpenFile(widget.path),
          icon: const Icon(Icons.folder_open_outlined, size: 16),
          label: Text(t.openInFiles),
        ),
      ],
    );
  }

  static String _name(String path) =>
      path.split(RegExp(r'[/\\]')).lastWhere((part) => part.isNotEmpty, orElse: () => path);
}

/// A compact line in place of a machine image: what is wrong, or that it loads, and an optional [action].
class _ImageNotice extends StatelessWidget {
  const _ImageNotice({required this.icon, required this.text, this.action});

  final IconData icon;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 8, 4),
      constraints: const BoxConstraints(minHeight: 40),
      decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(AppSizes.radius)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Flexible(child: Text(text, maxLines: 3, overflow: TextOverflow.ellipsis)),
          if (action case final action?) ...[const SizedBox(width: 8), action],
        ],
      ),
    );
  }
}
