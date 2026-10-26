import 'dart:math' as math;

import '../i18n/strings.g.dart';

/// [duration] as omp's TUI writes a loop's time left (`formatLoopLimit`, `status-line/segments.ts`): `1h30m`, `4m30s`,
/// `45s` (German `1 h 30 min`), in whole seconds rounded up.
String compactDuration(Duration duration) {
  final total = math.max(0, (duration.inMilliseconds / 1000).ceil());
  final hours = total ~/ 3600;
  final minutes = total % 3600 ~/ 60;
  final seconds = total % 60;
  final units = t.units;
  String pair(String big, int small, String Function({required Object value}) smallUnit) => small > 0
      ? units.pair(
          big: big,
          small: smallUnit(value: small),
        )
      : big;
  if (hours > 0) return pair(units.hours(value: hours), minutes, units.minutes);
  if (minutes > 0) return pair(units.minutes(value: minutes), seconds, units.seconds);
  return units.seconds(value: seconds);
}
