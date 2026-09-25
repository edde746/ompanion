import 'package:crypto/crypto.dart';

import '../transport/host_link.dart';
import 'scripts.dart';

/// Puts the companion extension at `~/.omp-app/companion/<ompVersion>/<sha256>.js` and returns its
/// host-native path, the value for omp's `-e`. The directory sits outside omp's extension discovery roots,
/// so the user's TUI never loads it. A file already there with the same content is left alone; a partial or
/// corrupt one is replaced. Uploads go to a temporary name first, so the final path only ever holds a
/// complete file.
Future<String> uploadCompanion(HostLink link, {required String ompVersion, required List<int> bytes}) async {
  if (!RegExp(r'^[0-9A-Za-z.+-]+$').hasMatch(ompVersion)) {
    throw ArgumentError.value(ompVersion, 'ompVersion', 'not a version');
  }
  final digest = sha256.convert(bytes).toString();
  final files = await link.files();
  try {
    final dir = await ensureAppDir(files, 'companion/$ompVersion');
    final path = '$dir/$digest.js';
    final existing = await files.stat(path);
    if (existing != null && existing.size == bytes.length) {
      if (sha256.convert(await files.read(path)).toString() == digest) return hostPath(path);
    }
    final temp = '$dir/$digest.${newMarker()}.part';
    await files.write(temp, bytes, mode: 0x180);
    if (existing != null) await files.remove(path);
    await files.rename(temp, path);
    return hostPath(path);
  } finally {
    await files.close();
  }
}
