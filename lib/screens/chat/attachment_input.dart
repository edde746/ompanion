import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:omp_core/rpc.dart';
import 'package:pasteboard/pasteboard.dart';
import 'package:path/path.dart' as p;

import '../../sessions/composer_attachments.dart';

/// Where pasted and dropped content comes from: the system clipboard and the OS's drag and drop in the app
/// ([SystemAttachmentSource]), a fake in tests, so they never touch the real clipboard.
abstract interface class AttachmentSource {
  /// Paths of the files and folders on the clipboard (copied in Finder or Explorer); empty when it holds none.
  Future<List<String>> clipboardFiles();

  /// The bitmap on the clipboard (a screenshot, an image copied in a browser) as PNG, JPEG, GIF or WebP, or null.
  Future<Uint8List?> clipboardImage();

  /// The plain text on the clipboard, or null.
  Future<String?> clipboardText();

  /// [child] as a target for files dragged in from the OS while [enabled]: [onHover] reports a drag entering (true)
  /// and leaving (false), [onDrop] the dropped paths.
  Widget dropTarget({
    required bool enabled,
    required ValueChanged<bool> onHover,
    required ValueChanged<List<String>> onDrop,
    required Widget child,
  });
}

/// What a paste puts into the composer.
sealed class Paste {
  const Paste();
}

/// Chips: copied files, an image, or a large text.
final class PasteAttachments extends Paste {
  const PasteAttachments(this.attachments);

  final List<ComposerAttachment> attachments;
}

/// Text typed in at the cursor.
final class PasteText extends Paste {
  const PasteText(this.text);

  final String text;
}

/// Reads a paste from [source] in the order the TUI and chat apps take the clipboard: copied files, then a bitmap,
/// then text. Text over 10 lines or 1000 characters becomes a chip ([isLargePaste]); null when there is nothing
/// to paste.
Future<Paste?> readPaste(AttachmentSource source) async {
  final files = await attachmentsFromPaths(await source.clipboardFiles());
  if (files.isNotEmpty) return PasteAttachments(files);
  final image = await source.clipboardImage();
  if (image != null) {
    final mimeType = imageMimeType(image);
    if (mimeType == null) throw const FormatException('The clipboard image is not PNG, JPEG, GIF or WebP.');
    return PasteAttachments([ImageAttachment(RpcImage(data: base64Encode(image), mimeType: mimeType))]);
  }
  final raw = await source.clipboardText();
  if (raw == null || raw.isEmpty) return null;
  final text = raw.replaceAll(RegExp('\r\n?'), '\n');
  return isLargePaste(text) ? PasteAttachments([TextAttachment(text)]) : PasteText(text);
}

/// Whether the TUI collapses a paste of [text] into a chip: over 10 lines or 1000 characters (its editor's
/// "marker-sized" paste).
bool isLargePaste(String text) => '\n'.allMatches(text).length + 1 > 10 || text.length > 1000;

/// Image types omp takes as image content, by file extension.
const _imageTypes = {'.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.gif': 'image/gif', '.webp': 'image/webp'};

/// The image type [bytes] start with, of those omp takes as image content, or null.
String? imageMimeType(Uint8List bytes) {
  bool at(int offset, List<int> magic) {
    if (bytes.length < offset + magic.length) return false;
    for (var i = 0; i < magic.length; i++) {
      if (bytes[offset + i] != magic[i]) return false;
    }
    return true;
  }

  if (at(0, const [0x89, 0x50, 0x4e, 0x47])) return 'image/png';
  if (at(0, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (at(0, const [0x47, 0x49, 0x46, 0x38])) return 'image/gif';
  if (at(0, const [0x52, 0x49, 0x46, 0x46]) && at(8, const [0x57, 0x45, 0x42, 0x50])) return 'image/webp';
  return null;
}

/// Attachments for files and folders on this device, as a drop, a paste of copied files or the file picker brings
/// them: an image omp takes as image content becomes an [ImageAttachment], as the TUI sends a pasted image; any other
/// file and a folder a [FileAttachment] the prompt mentions. Paths that name nothing on disk are left out: a link
/// dragged from a browser arrives as its URL.
Future<List<ComposerAttachment>> attachmentsFromPaths(Iterable<String> paths) async {
  final attachments = <ComposerAttachment>[];
  for (final path in paths) {
    final name = p.basename(path);
    switch (await FileSystemEntity.type(path)) {
      case FileSystemEntityType.directory:
        attachments.add(FileAttachment.path(name: name, size: 0, path: path));
      case FileSystemEntityType.file:
        final file = File(path);
        final mimeType = _imageTypes[p.extension(path).toLowerCase()];
        attachments.add(
          mimeType == null
              ? FileAttachment.path(name: name, size: await file.length(), path: path)
              : ImageAttachment(RpcImage(data: base64Encode(await file.readAsBytes()), mimeType: mimeType), name: name),
        );
      case FileSystemEntityType.notFound:
      case FileSystemEntityType.link:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
      // Nothing to attach: a browser's link, a socket.
    }
  }
  return attachments;
}

/// The attachment for a file the picker hands over as bytes only (an Android document without a path), as
/// [attachmentsFromPaths] would make it from a path.
ComposerAttachment attachmentFromBytes(String name, Uint8List bytes) {
  final mimeType = _imageTypes[p.extension(name).toLowerCase()];
  return mimeType == null
      ? FileAttachment.bytes(name: name, bytes: bytes)
      : ImageAttachment(RpcImage(data: base64Encode(bytes), mimeType: mimeType), name: name);
}

/// The system clipboard through `pasteboard`, drops through `desktop_drop`. Copied files and drops exist on macOS,
/// Windows and Linux only: Android hands out content URIs, not paths, and iOS has neither.
final class SystemAttachmentSource implements AttachmentSource {
  const SystemAttachmentSource();

  static bool get _desktop => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

  @override
  Future<List<String>> clipboardFiles() async {
    if (!_desktop) return const [];
    // macOS reads a browser's copied link as a URL too, and pasteboard returns its path (`/` for a site's front
    // page), which names a folder here. Finder puts the file names on the clipboard as text, a browser the link.
    if (Platform.isMacOS) {
      final link = Uri.tryParse((await clipboardText())?.trim() ?? '');
      if (link != null && link.hasScheme && !link.isScheme('file')) return const [];
    }
    return Pasteboard.files();
  }

  @override
  Future<Uint8List?> clipboardImage() async {
    final image = await Pasteboard.image;
    if (image == null || imageMimeType(image) != null) return image;
    // Windows hands out a BMP, Android whatever the copying app shared.
    final codec = await ui.instantiateImageCodec(image);
    final decoded = (await codec.getNextFrame()).image;
    final png = await decoded.toByteData(format: ui.ImageByteFormat.png);
    decoded.dispose();
    codec.dispose();
    return png?.buffer.asUint8List();
  }

  @override
  Future<String?> clipboardText() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;

  @override
  Widget dropTarget({
    required bool enabled,
    required ValueChanged<bool> onHover,
    required ValueChanged<List<String>> onDrop,
    required Widget child,
  }) {
    if (!_desktop) return child;
    return DropTarget(
      enable: enabled,
      onDragEntered: (_) => onHover(true),
      onDragExited: (_) => onHover(false),
      onDragDone: (details) => onDrop([for (final file in details.files) file.path]),
      child: child,
    );
  }
}
