import 'dart:math' as math;

/// [duration] as omp's TUI writes a loop's time left (`formatLoopLimit`, `status-line/segments.ts`): `1h30m`, `4m30s`,
/// `45s`, in whole seconds rounded up.
String compactDuration(Duration duration) {
  final total = math.max(0, (duration.inMilliseconds / 1000).ceil());
  final hours = total ~/ 3600;
  final minutes = total % 3600 ~/ 60;
  final seconds = total % 60;
  if (hours > 0) return '${hours}h${minutes > 0 ? '${minutes}m' : ''}';
  if (minutes > 0) return '${minutes}m${seconds > 0 ? '${seconds}s' : ''}';
  return '${seconds}s';
}
