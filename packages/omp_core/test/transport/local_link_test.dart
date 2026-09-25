import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late LocalLink link;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('local-link-');
    link = LocalLink(environment: {'HOME': temp.path});
  });

  tearDown(() async {
    await link.close();
    await temp.delete(recursive: true);
  });

  test('exec feeds stdin, separates stdout and stderr, and reports the exit code', () async {
    final process = await link.exec('cat; echo oops >&2; exit 3');
    process.write(utf8.encode('hello\n'));
    await process.closeStdin();
    final out = await utf8.decodeStream(process.stdout);
    final err = await utf8.decodeStream(process.stderr);
    expect(out, 'hello\n');
    expect(err, 'oops\n');
    expect((await process.exit).code, 3);
  });

  test('decodeLines keeps a multi-byte character split across chunks', () async {
    final bytes = utf8.encode('{"a":"é"}\n{"b":1}\n');
    final chunks = Stream.fromIterable([bytes.sublist(0, 7), bytes.sublist(7)]).map((c) => Uint8List.fromList(c));
    expect(await decodeLines(chunks).toList(), ['{"a":"é"}', '{"b":1}']);
  });

  test('mkdir is exclusive, so it works as a lock', () async {
    final files = await link.files();
    final lock = '${await files.home()}/lock';
    await files.mkdir(lock);
    await expectLater(files.mkdir(lock), throwsA(isA<HostFileExists>()));
    await files.removeDir(lock);
    await files.mkdir(lock);
  });

  test('write appends and read honours offset and length', () async {
    final files = await link.files();
    final path = '${await files.home()}/log.jsonl';
    await files.write(path, utf8.encode('abc'));
    await files.write(path, utf8.encode('def'), append: true);
    expect(utf8.decode(await files.read(path, offset: 2, length: 3)), 'cde');
    expect(utf8.decode(await files.read(path, offset: 4)), 'ef');
    expect((await files.stat(path))!.size, 6);
    expect(await files.stat('$path.missing'), isNull);
  });
}
