import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/utils/byte_size.dart';

const _sizes = [512, 4300, 89088, 12897484, 2362232013];

void main() {
  test('steps of 1024, one decimal except from 10 KB to 1 MB', () {
    expect([for (final bytes in _sizes) formatBytes(bytes)], ['512 B', '4.2 KB', '87 KB', '12.3 MB', '2.2 GB']);
  });

  group('in German', () {
    setUp(() => LocaleSettings.setLocaleSync(AppLocale.de));
    tearDown(() => LocaleSettings.setLocaleSync(AppLocale.en));

    test('the decimal is a comma', () {
      expect([for (final bytes in _sizes) formatBytes(bytes)], ['512 B', '4,2 KB', '87 KB', '12,3 MB', '2,2 GB']);
    });
  });
}
