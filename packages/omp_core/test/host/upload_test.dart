import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late LocalLink link;
  late HostFiles files;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('upload-');
    link = LocalLink(environment: {'HOME': temp.path});
    files = await link.files();
  });

  tearDown(() async {
    await files.close();
    await link.close();
    await temp.delete(recursive: true);
  });

  test('an upload creates the missing directories, keeps its name and never replaces an earlier upload', () async {
    final dir = '${temp.path}/sessions/s1/local';
    final progress = <int>[];
    final first = await uploadAttachment(
      files,
      dir: dir,
      name: 'notes v2.txt',
      bytes: Stream.fromIterable([Uint8List(3 << 20), Uint8List(3 << 20)]),
      onProgress: progress.add,
    );
    final second = await uploadAttachment(files, dir: dir, name: 'notes v2.txt', bytes: Stream.value('two'.codeUnits));
    final third = await uploadAttachment(files, dir: dir, name: 'notes v2.txt', bytes: Stream.value('three'.codeUnits));
    final bare = await uploadAttachment(files, dir: dir, name: 'Makefile', bytes: Stream.value('a'.codeUnits));
    final bareAgain = await uploadAttachment(files, dir: dir, name: 'Makefile', bytes: Stream.value('b'.codeUnits));

    expect(
      [first, second, third, bare, bareAgain],
      ['$dir/notes v2.txt', '$dir/notes v2-2.txt', '$dir/notes v2-3.txt', '$dir/Makefile', '$dir/Makefile-2'],
    );
    expect(File(first).lengthSync(), 6 << 20);
    expect(File(third).readAsStringSync(), 'three');
    expect(File(bareAgain).readAsStringSync(), 'b');
    expect(progress, [4 << 20, 6 << 20]);
    if (!Platform.isWindows) expect(File(first).statSync().mode & 0x1FF, 0x180);
  });

  test('a name a machine or a quoted mention cannot carry is made safe', () async {
    final dir = '${temp.path}/local';
    final paths = [
      for (final name in ['a/b\\c:d".txt', ' .env ', 'report.', '..'])
        await uploadAttachment(files, dir: dir, name: name, bytes: Stream.value(const [1])),
    ];
    expect(paths.map((path) => path.substring(dir.length + 1)), ['a_b_c_d_.txt', '.env', 'report', 'attachment']);
  });

  test('an upload that fails midway leaves no file behind', () async {
    final dir = '${temp.path}/local';
    Stream<List<int>> broken() async* {
      yield Uint8List(5 << 20);
      throw const FileSystemException('the source vanished');
    }

    await expectLater(
      uploadAttachment(files, dir: dir, name: 'big.bin', bytes: broken()),
      throwsA(isA<FileSystemException>()),
    );
    expect(Directory(dir).listSync(), isEmpty);
  });

  test('pastes are numbered as the TUI numbers its paste files, skipping taken numbers', () async {
    final dir = '${temp.path}/local';
    Directory(dir).createSync();
    File('$dir/paste-2.md').writeAsStringSync('older');

    final names = [await savePaste(files, dir: dir, text: 'first'), await savePaste(files, dir: dir, text: 'third ✓')];

    expect(names, ['paste-1.md', 'paste-3.md']);
    expect(File('$dir/paste-3.md').readAsStringSync(), 'third ✓');
    expect(File('$dir/paste-2.md').readAsStringSync(), 'older');
  });
}
