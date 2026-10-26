import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/utils/compact_duration.dart';

const _durations = [
  Duration(hours: 1, minutes: 30),
  Duration(hours: 2),
  Duration(minutes: 4, seconds: 30),
  Duration(seconds: 44, milliseconds: 100),
];

void main() {
  test("omp's loop time: two units at most, whole seconds rounded up", () {
    expect([for (final duration in _durations) compactDuration(duration)], ['1h30m', '2h', '4m30s', '45s']);
  });

  group('in German', () {
    setUp(() => LocaleSettings.setLocaleSync(AppLocale.de));
    tearDown(() => LocaleSettings.setLocaleSync(AppLocale.en));

    test('the units are spaced SI symbols', () {
      expect(
        [for (final duration in _durations) compactDuration(duration)],
        ['1 h 30 min', '2 h', '4 min 30 s', '45 s'],
      );
    });
  });
}
