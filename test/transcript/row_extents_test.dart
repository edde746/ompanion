import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/chat/transcript/row_extents.dart';
import 'package:ompanion/screens/chat/transcript/transcript_rows.dart';
import 'package:omp_core/store.dart';

AssistantTextRow _text(String text) => AssistantTextRow(
  AssistantItem(timestamp: 1, content: [TextBlock(text)], provider: 'fake', model: 'fake-1', stopReason: StopReason.stop),
  0,
  text,
);

void main() {
  test('a row counts its measured height at the width it was measured, and its estimate at any other width', () {
    final extents = RowExtents();
    final row = _text('A short answer.');
    extents.measured('other', 800, 30);
    final estimate = extents.of(row);
    expect(estimate, estimateRowExtent(row, 800));

    extents.measured(row.key, 800, 123);
    expect(extents.of(row), 123);

    // Text wraps anew at another width: the heights measured at 800 no longer hold.
    extents.measured('other', 400, 60);
    expect(extents.of(row), estimateRowExtent(row, 400));
  });

  test('estimates grow with wrapped prose and with code lines, and shrink as the column widens', () {
    final prose = 'word ' * 400;
    expect(estimateRowExtent(_text(prose), 500), greaterThan(estimateRowExtent(_text(prose), 900)));
    expect(estimateRowExtent(_text(prose), 800), greaterThan(estimateRowExtent(_text('word ' * 40), 800)));
    final code = ['```', for (var line = 0; line < 30; line++) 'x = $line', '```'].join('\n');
    expect(estimateRowExtent(_text(code), 800), greaterThan(30 * 15));
  });
}
