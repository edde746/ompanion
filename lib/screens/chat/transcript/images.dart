import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:omp_core/store.dart';

import '../../../app/theme.dart';
import '../../../i18n/strings.g.dart';

final _bytes = Expando<Uint8List>();
final _sizes = Expando<Size>();

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

/// Width and height from an image file header.
Size? sniffImageSize(Uint8List b) {
  int be16(int i) => b[i] << 8 | b[i + 1];
  int le16(int i) => b[i] | b[i + 1] << 8;
  int be32(int i) => b[i] << 24 | b[i + 1] << 16 | b[i + 2] << 8 | b[i + 3];
  if (b.length >= 24 && b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4e && b[3] == 0x47) {
    return Size(be32(16).toDouble(), be32(20).toDouble());
  }
  if (b.length >= 10 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
    return Size(le16(6).toDouble(), le16(8).toDouble());
  }
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
        onTap: () => showDialog<void>(context: context, builder: (context) => _ZoomedImage(image)),
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

class _ZoomedImage extends StatelessWidget {
  const _ZoomedImage(this.image);

  final ImageBlock image;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      insetPadding: const EdgeInsets.all(24),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          InteractiveViewer(maxScale: 8, child: Center(child: Image.memory(imageBytes(image)))),
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
