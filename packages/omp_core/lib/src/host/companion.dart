import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../channel/replay.dart';
import '../transport/host_link.dart';
import 'scripts.dart';

/// Puts the companion extension at `~/.ompanion/companion/<ompVersion>/<sha256>.js` and [replayScript] next to it at
/// `replay.<sha256>.js`, and returns their host-native paths: the companion's is the value for omp's `-e`. The
/// directory sits outside omp's extension discovery roots, so the user's TUI never loads either. A file already there
/// with the same content is left alone; a partial or corrupt one is replaced. Uploads go to a temporary name first,
/// so a final path only ever holds a complete file.
Future<({String companion, String replay})> uploadCompanion(
  HostLink link, {
  required String ompVersion,
  required List<int> bytes,
}) async {
  if (!RegExp(r'^[0-9A-Za-z.+-]+$').hasMatch(ompVersion)) {
    throw ArgumentError.value(ompVersion, 'ompVersion', 'not a version');
  }
  final files = await link.files();
  try {
    final dir = await ensureAppDir(files, 'companion/$ompVersion');
    Future<String> put(String prefix, List<int> content) async {
      final digest = sha256.convert(content).toString();
      final path = '$dir/$prefix$digest.js';
      final existing = await files.stat(path);
      if (existing != null && existing.size == content.length) {
        if (sha256.convert(await files.read(path)).toString() == digest) return hostPath(path);
      }
      final temp = '$dir/$prefix$digest.${newMarker()}.part';
      await files.write(temp, content, mode: 0x180);
      if (existing != null) await files.remove(path);
      await files.rename(temp, path);
      return hostPath(path);
    }

    return (companion: await put('', bytes), replay: await put('replay.', utf8.encode(replayScript)));
  } finally {
    await files.close();
  }
}
