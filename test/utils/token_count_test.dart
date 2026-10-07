import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/utils/token_count.dart';

void main() {
  test('whole values drop the decimal, others keep one, in K below a million, M below a billion, B from there', () {
    final cases = {
      0: '0',
      999: '999',
      1000: '1K',
      1234: '1.2K',
      12345: '12.3K',
      128000: '128K',
      200000: '200K',
      128500: '128.5K',
      999949: '999.9K',
      // Rounding up to 1000K reads as the next unit.
      999960: '1M',
      1000000: '1M',
      1048576: '1M',
      1500000: '1.5M',
      2000000: '2M',
      10250000: '10.3M',
      999949999: '999.9M',
      999960000: '1B',
      17406968354: '17.4B',
    };
    for (final MapEntry(key: tokens, value: text) in cases.entries) {
      expect(formatTokens(tokens), text, reason: '$tokens tokens');
    }
  });
}
