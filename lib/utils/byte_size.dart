/// [bytes] for people: `512 B`, `4.2 KB`, `87 KB`, `12.3 MB`, in steps of 1024.
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
