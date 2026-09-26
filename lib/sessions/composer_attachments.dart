import 'dart:typed_data';

import 'package:omp_core/rpc.dart';

/// Something attached to a prompt in the composer: pasted, dropped or picked. Plain data; turning it into what omp
/// receives (upload, `@` mention, inline text) happens when the prompt is sent.
sealed class ComposerAttachment {
  const ComposerAttachment();
}

/// An image sent with the prompt as image content, as the TUI sends a pasted image.
final class ImageAttachment extends ComposerAttachment {
  const ImageAttachment(this.image, {this.name});

  final RpcImage image;

  /// The file name when the image came from a file; null for a pasted bitmap.
  final String? name;
}

/// A file from this device. It goes to the session's machine and the prompt mentions it, so omp reads it the way it
/// reads an `@path` typed in the TUI. Exactly one of [path] and [bytes] is set: a picked or dropped file keeps its
/// path, a pasted one arrives as bytes.
final class FileAttachment extends ComposerAttachment {
  const FileAttachment.path({required this.name, required this.size, required String this.path}) : bytes = null;

  const FileAttachment.bytes({required this.name, required Uint8List this.bytes}) : path = null, size = bytes.length;

  final String name;
  final int size;
  final String? path;
  final Uint8List? bytes;
}

/// A large paste kept out of the text field, as the TUI collapses it into a text-attachment chip; its text goes into
/// the message when the prompt is sent.
final class TextAttachment extends ComposerAttachment {
  const TextAttachment(this.text);

  final String text;

  int get lineCount => '\n'.allMatches(text).length + 1;
}
