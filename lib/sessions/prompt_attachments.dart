import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';

import '../i18n/strings.g.dart';
import '../utils/byte_size.dart';
import 'composer_attachments.dart';

/// What omp receives for a composed prompt: [message] with every attachment turned into text omp understands
/// (expanded paste, `@` mention of an uploaded file), and the images to send as image content.
typedef PreparedPrompt = ({String message, List<RpcImage> images});

/// The largest file a prompt takes. omp auto-reads text up to 5 MB and images up to 25 MB and names a larger file by
/// its path only, so beyond this the upload costs more than the model gains.
const maxAttachmentBytes = 100 << 20;

/// A paste above this many UTF-8 bytes goes to the session's `local://` store as `paste-<n>.md`, which the message
/// names, as the TUI's "Attach as local file" does: inline it would take a large share of the model's context.
const pasteFileThreshold = 256 << 10;

/// Turns [attachments] into what omp receives with [text] (the composer's trimmed text):
/// - an [ImageAttachment] is image content; omp resizes it as it resizes a mentioned image;
/// - a [TextAttachment] is its text, or `local://paste-<n>.md` above [pasteFileThreshold];
/// - a [FileAttachment] is an `@` mention of the file's path on the session's machine, which omp auto-reads. On this
///   computer a file with a path is mentioned where it is; any other file is uploaded into the session's `local://`
///   directory (companion verb `session.localRoot`), whose lifecycle is omp's: deleting the session deletes it.
///
/// [link] opens the session's machine; it is called only when a file or a large paste needs the machine.
/// [onUploadProgress] reports the bytes written to the machine so far and in all. Throws [AttachmentException].
Future<PreparedPrompt> preparePrompt({
  required String text,
  required List<ComposerAttachment> attachments,
  required LiveSession session,
  required Future<HostLink> Function() link,
  void Function(int sent, int total)? onUploadProgress,
}) async {
  final images = [
    for (final attachment in attachments)
      if (attachment case ImageAttachment(:final image)) image,
  ];
  final pasteSizes = {
    for (final attachment in attachments)
      if (attachment case TextAttachment(:final text)) attachment: utf8.encode(text).length,
  };
  final fileSizes = <FileAttachment, int>{};
  for (final file in attachments.whereType<FileAttachment>()) {
    fileSizes[file] = await _sizeOf(file);
  }
  final bigPastes = {
    for (final MapEntry(key: paste, value: size) in pasteSizes.entries)
      if (size > pasteFileThreshold) paste,
  };

  // Null until a file or a large paste needs the machine.
  HostLink? host;
  if (fileSizes.isNotEmpty || bigPastes.isNotEmpty) {
    try {
      host = await link();
    } on Exception catch (error) {
      throw AttachmentUploadFailed(fileSizes.keys.firstOrNull?.name, error);
    }
  }
  final local = host is LocalLink;

  final uploads = [
    for (final attachment in attachments)
      if (attachment is FileAttachment && !(local && _mentionableInPlace(attachment)))
        attachment
      else if (bigPastes.contains(attachment))
        attachment,
  ];
  for (final upload in uploads) {
    if (upload is FileAttachment && fileSizes[upload]! < 0) throw AttachmentIsFolder(upload.name);
  }

  // Where each upload landed: a host-native path for a file, a `local://` name for a paste.
  final written = <ComposerAttachment, String>{};
  if (uploads.isNotEmpty) {
    String? nameOf(ComposerAttachment upload) => upload is FileAttachment ? upload.name : null;
    int sizeOf(ComposerAttachment upload) => upload is FileAttachment ? fileSizes[upload]! : pasteSizes[upload]!;
    if (session.companionHello == null) throw AttachmentNeedsCompanion(nameOf(uploads.first));
    final String root;
    final HostFiles files;
    try {
      final reply = await session.companion.call('session.localRoot');
      root = toSftpPath(asJsonObject(reply, 'session.localRoot').string('path'));
      files = await host!.files();
    } on Exception catch (error) {
      throw AttachmentUploadFailed(nameOf(uploads.first), error);
    }
    try {
      final total = uploads.fold(0, (sum, upload) => sum + sizeOf(upload));
      var done = 0;
      void progress(int sent) => onUploadProgress?.call(done + sent, total);
      progress(0);
      for (final upload in uploads) {
        try {
          if (upload case FileAttachment(:final name, :final path, :final bytes)) {
            final source = path != null ? File(path).openRead() : Stream.value(bytes!);
            final target = await uploadAttachment(files, dir: root, name: name, bytes: source, onProgress: progress);
            written[upload] = hostPath(target);
          } else if (upload case TextAttachment(:final text)) {
            written[upload] = 'local://${await savePaste(files, dir: root, text: text, onProgress: progress)}';
          }
        } on Exception catch (error) {
          throw AttachmentUploadFailed(nameOf(upload), error);
        }
        done += sizeOf(upload);
      }
    } finally {
      await files.close();
    }
  }

  final parts = [
    for (final attachment in attachments)
      switch (attachment) {
        ImageAttachment() => null,
        TextAttachment(:final text) => written[attachment] ?? text,
        FileAttachment(:final name, :final path) => _mention(name, written[attachment] ?? File(path!).absolute.path),
      },
  ].nonNulls.toList();
  return (message: assembleMessage(text, parts), images: images);
}

String _mention(String name, String path) =>
    fileMention(path) ?? (throw AttachmentUploadFailed(name, 'no @ mention can carry the path $path'));

/// The file's size now, -1 for a folder. Throws [AttachmentMissing] and [AttachmentTooLarge].
Future<int> _sizeOf(FileAttachment file) async {
  final path = file.path;
  if (path == null) {
    if (file.size > maxAttachmentBytes) throw AttachmentTooLarge(file.name, file.size);
    return file.size;
  }
  final stat = await FileStat.stat(path);
  switch (stat.type) {
    case FileSystemEntityType.notFound:
      throw AttachmentMissing(file.name);
    case FileSystemEntityType.directory:
      return -1;
    default:
      if (stat.size > maxAttachmentBytes) throw AttachmentTooLarge(file.name, stat.size);
      return stat.size;
  }
}

/// A file or folder on this computer that omp, running here too, reads where it is.
bool _mentionableInPlace(FileAttachment file) =>
    file.path != null && fileMention(File(file.path!).absolute.path) != null;

/// [text] with [parts] appended as the TUI expands chips inserted at the end of the typed text: after a space unless
/// the text ends in whitespace, one space between parts (the space the TUI puts after a chip), and the whole message
/// trimmed as the TUI trims it on submit.
String assembleMessage(String text, List<String> parts) {
  if (parts.isEmpty) return text.trim();
  final separator = text.isEmpty || text.trimRight().length != text.length ? '' : ' ';
  return '$text$separator${parts.join(' ')}'.trim();
}

/// An `@` mention omp resolves to [path] (host-native; file-mentions.ts `FILE_MENTION_REGEX`): `@"path"`, or `@'path'`
/// when the path has a double quote. Null when it has both quotes or starts or ends with whitespace, which no quoted
/// mention keeps.
String? fileMention(String path) {
  if (path.isEmpty || path.trim().length != path.length) return null;
  if (!path.contains('"')) return '@"$path"';
  if (!path.contains("'")) return "@'$path'";
  return null;
}

/// Why a prompt with attachments was not sent. [name] is the file's name; null for a paste.
sealed class AttachmentException implements Exception {
  const AttachmentException(this.name);

  final String? name;

  /// The user-facing message.
  String describe(Translations t);

  String _label(Translations t) => name ?? t.attachments.paste;
}

/// A file with a path is no longer on this device.
final class AttachmentMissing extends AttachmentException {
  const AttachmentMissing(String super.name);

  @override
  String describe(Translations t) => t.attachments.missing(name: _label(t));
}

/// A file above [maxAttachmentBytes].
final class AttachmentTooLarge extends AttachmentException {
  const AttachmentTooLarge(String super.name, this.size);

  final int size;

  @override
  String describe(Translations t) =>
      t.attachments.tooLarge(name: _label(t), size: formatBytes(size), limit: formatBytes(maxAttachmentBytes));
}

/// A folder attached to a session on another machine; folders are only mentioned where they are.
final class AttachmentIsFolder extends AttachmentException {
  const AttachmentIsFolder(String super.name);

  @override
  String describe(Translations t) => t.attachments.folder(name: _label(t));
}

/// The session has no companion to name its `local://` directory.
final class AttachmentNeedsCompanion extends AttachmentException {
  const AttachmentNeedsCompanion(super.name);

  @override
  String describe(Translations t) => t.attachments.needsCompanion(name: _label(t));
}

/// Reaching the machine, the companion or the file failed while copying [name] to the machine.
final class AttachmentUploadFailed extends AttachmentException {
  const AttachmentUploadFailed(super.name, this.cause);

  final Object cause;

  @override
  String describe(Translations t) => t.attachments.uploadFailed(name: _label(t), error: '$cause');
}
