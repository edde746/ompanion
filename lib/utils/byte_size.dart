import 'number_format.dart';

/// [bytes] for people: `512 B`, `4.2 KB`, `87 KB`, `12.3 MB`, `2.2 GB` (German `4,2 KB`), in steps of 1024.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${formatFixed(bytes / 1024, bytes < 10 * 1024 ? 1 : 0)} KB';
  if (bytes < 1024 * 1024 * 1024) return '${formatFixed(bytes / (1024 * 1024), 1)} MB';
  return '${formatFixed(bytes / (1024 * 1024 * 1024), 1)} GB';
}
