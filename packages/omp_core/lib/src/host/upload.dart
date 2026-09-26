import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../transport/host_link.dart';

const _chunkSize = 4 << 20;

/// Streams [bytes] to [path] (SFTP path space) in 4 MiB appends, so a large file is never held in memory at once.
/// [mode] applies on creation; [onProgress] gets the bytes written so far after every append.
Future<void> writeStream(
  HostFiles files,
  String path,
  Stream<List<int>> bytes, {
  int? mode,
  void Function(int written)? onProgress,
}) async {
  final chunk = BytesBuilder(copy: false);
  var first = true;
  var written = 0;
  Future<void> flush() async {
    final data = chunk.takeBytes();
    await files.write(path, data, append: !first, mode: first ? mode : null);
    first = false;
    written += data.length;
    onProgress?.call(written);
  }

  await for (final part in bytes) {
    final view = part is Uint8List ? part : Uint8List.fromList(part);
    for (var offset = 0; offset < view.length;) {
      final take = min(_chunkSize - chunk.length, view.length - offset);
      chunk.add(Uint8List.sublistView(view, offset, offset + take));
      offset += take;
      if (chunk.length == _chunkSize) await flush();
    }
  }
  if (first || chunk.length > 0) await flush();
}

/// Uploads [bytes] as [name] into [dir] (SFTP path space), creating [dir] and its missing parents. The name is made
/// safe first ([safeFileName]); a name already in [dir] gets `-2`, `-3`, … before its extension, so an earlier upload
/// stays as it was. Only the owner can read the file. A failed upload is removed. Returns the file's SFTP path.
Future<String> uploadAttachment(
  HostFiles files, {
  required String dir,
  required String name,
  required Stream<List<int>> bytes,
  void Function(int written)? onProgress,
}) async {
  await makeDirectories(files, dir);
  final safe = safeFileName(name);
  final dot = safe.lastIndexOf('.');
  final (stem, extension) = dot > 0 ? (safe.substring(0, dot), safe.substring(dot)) : (safe, '');
  var path = '$dir/$safe';
  for (var n = 2; await files.stat(path, followLinks: false) != null; n++) {
    path = '$dir/$stem-$n$extension';
  }
  await _writeOrRemove(files, path, bytes, onProgress);
  return path;
}

/// Saves [text] in [dir] (SFTP path space) as `paste-<n>.md`, n the first number without a file, as the TUI's "Attach
/// as local file" names a large paste in the session's `local://` store. Returns the file name.
Future<String> savePaste(
  HostFiles files, {
  required String dir,
  required String text,
  void Function(int written)? onProgress,
}) async {
  await makeDirectories(files, dir);
  var n = 1;
  while (await files.stat('$dir/paste-$n.md', followLinks: false) != null) {
    n++;
  }
  await _writeOrRemove(files, '$dir/paste-$n.md', Stream.value(utf8.encode(text)), onProgress);
  return 'paste-$n.md';
}

Future<void> _writeOrRemove(
  HostFiles files,
  String path,
  Stream<List<int>> bytes,
  void Function(int written)? onProgress,
) async {
  try {
    await writeStream(files, path, bytes, mode: 0x180, onProgress: onProgress);
  } on Object catch (error, stack) {
    try {
      if (await files.stat(path, followLinks: false) != null) await files.remove(path);
    } on Object {
      // The link is gone as well; the partial file stays, under a name the next upload skips.
      Error.throwWithStackTrace(error, stack);
    }
    rethrow;
  }
}

/// Creates [dir] (SFTP path space) and its missing parents, each only its owner can enter.
Future<void> makeDirectories(HostFiles files, String dir) async {
  final stat = await files.stat(dir);
  if (stat != null) {
    if (!stat.isDirectory) throw HostLinkException('$dir is not a directory');
    return;
  }
  final cut = dir.lastIndexOf('/');
  if (cut > 0) await makeDirectories(files, dir.substring(0, cut));
  try {
    await files.mkdir(dir, mode: 0x1C0);
  } on HostFileExists {
    // Another device made it meanwhile.
    return;
  }
}

/// [name] as a file name every machine accepts and a quoted `@"…"` mention can carry: path separators, control
/// characters and what Windows forbids (`<>:"|?*`) become `_`; leading spaces and trailing spaces and dots go.
String safeFileName(String name) {
  final safe = name
      .replaceAll(RegExp(r'[\x00-\x1f<>:"/\\|?*]'), '_')
      .replaceFirst(RegExp(r'^\s+'), '')
      .replaceFirst(RegExp(r'[\s.]+$'), '');
  return safe.isEmpty ? 'attachment' : safe;
}
