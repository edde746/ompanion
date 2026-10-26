import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/utils/number_format.dart';

void main() {
  test('English groups with commas and writes decimals, percentages and dollars as Dart and omp do', () {
    expect(formatCount(128767), '128,767');
    expect(formatCount(-1234567), '-1,234,567');
    expect(formatFixed(1234.56, 1), '1234.6');
    expect(formatPercent(0.1234), '12.3%');
    expect(formatUsd(0.01234, 4), '\$0.0123');
  });

  group('in German', () {
    setUp(() => LocaleSettings.setLocaleSync(AppLocale.de));
    tearDown(() => LocaleSettings.setLocaleSync(AppLocale.en));

    test('groups with dots, writes decimals with a comma and puts a space before % and \$', () {
      expect(formatCount(128767), '128.767');
      expect(formatCount(-1234567), '-1.234.567');
      expect(formatFixed(1234.56, 1), '1234,6');
      expect(formatPercent(0.1234), '12,3 %');
      expect(formatUsd(0.01234, 4), '0,0123 \$');
    });
  });
}
