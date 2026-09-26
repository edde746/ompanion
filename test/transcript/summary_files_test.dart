import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/chat/transcript/summary_files.dart';

void main() {
  test("omp's <files> block becomes paths under their directory headings, out of the prose", () {
    final summary = splitSummaryFiles(
      '## Summary\nDid things.\n\n<files>\nREADME.md (Read)\n# lib/\nmain.dart (RW)\n## screens/chat/\nchat.dart (Write)\n'
      '# test/\nmain_test.dart (Read)\n[…3 files elided…]\n</files>\n',
    );
    expect(summary.text, '## Summary\nDid things.');
    expect(summary.files, [
      (path: 'README.md', operation: SummaryFileOperation.read),
      (path: 'lib/main.dart', operation: SummaryFileOperation.readWrite),
      (path: 'lib/screens/chat/chat.dart', operation: SummaryFileOperation.write),
      (path: 'test/main_test.dart', operation: SummaryFileOperation.read),
    ]);
    expect(summary.elided, 3);
  });

  test('the older read-files and modified-files blocks', () {
    final summary = splitSummaryFiles(
      'Text\n<read-files>\na.md\n</read-files>\n<modified-files>\nb.md\n</modified-files>',
    );
    expect(summary.text, 'Text');
    expect(summary.files, [
      (path: 'a.md', operation: SummaryFileOperation.read),
      (path: 'b.md', operation: SummaryFileOperation.write),
    ]);
  });
}
