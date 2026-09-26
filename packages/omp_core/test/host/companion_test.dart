import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late LocalLink link;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('companion-');
    link = LocalLink(environment: {'HOME': temp.path});
  });

  tearDown(() async {
    await link.close();
    await temp.delete(recursive: true);
  });

  test('the companion lands at a content-addressed path, is kept when intact and replaced when not', () async {
    final bytes = utf8.encode('export default function () {}\n');
    final path = await uploadCompanion(link, ompVersion: '18.3.1', bytes: bytes);
    expect(path, '${temp.path}/.ompanion/companion/18.3.1/${sha256.convert(bytes)}.js');
    expect(File(path).readAsBytesSync(), bytes);

    await Process.run('touch', ['-t', '202001010000', path]);
    expect(await uploadCompanion(link, ompVersion: '18.3.1', bytes: bytes), path);
    expect(File(path).statSync().modified.year, 2020, reason: 'an intact copy is not uploaded again');

    File(path).writeAsBytesSync(List.filled(bytes.length, 0x20));
    expect(await uploadCompanion(link, ompVersion: '18.3.1', bytes: bytes), path);
    expect(File(path).readAsBytesSync(), bytes, reason: 'a corrupt copy of the same size is replaced');
    expect(Directory(File(path).parent.path).listSync(), hasLength(1), reason: 'no temporary file is left behind');
  });
}
