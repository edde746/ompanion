import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/src/channel/follow.dart' show followScript;
import 'package:omp_core/src/channel/log_script.dart' show logScript;
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

  test(
    'the companion and the host scripts land at content-addressed paths, kept when intact, replaced when not',
    () async {
      final bytes = utf8.encode('export default function () {}\n');
      final paths = await uploadCompanion(link, ompVersion: '18.3.1', bytes: bytes);
      final path = paths.companion;
      final dir = '${temp.path}/.ompanion/companion/18.3.1';
      expect(path, '$dir/${sha256.convert(bytes)}.js');
      expect(File(path).readAsBytesSync(), bytes);
      expect(paths.log, '$dir/log.${sha256.convert(utf8.encode(logScript))}.js');
      expect(File(paths.log).readAsStringSync(), logScript);
      expect(paths.follow, '$dir/follow.${sha256.convert(utf8.encode(followScript))}.js');
      expect(File(paths.follow).readAsStringSync(), followScript);

      await Process.run('touch', ['-t', '202001010000', path]);
      expect((await uploadCompanion(link, ompVersion: '18.3.1', bytes: bytes)).companion, path);
      expect(File(path).statSync().modified.year, 2020, reason: 'an intact copy is not uploaded again');

      File(path).writeAsBytesSync(List.filled(bytes.length, 0x20));
      expect((await uploadCompanion(link, ompVersion: '18.3.1', bytes: bytes)).companion, path);
      expect(File(path).readAsBytesSync(), bytes, reason: 'a corrupt copy of the same size is replaced');
      expect(Directory(dir).listSync(), hasLength(3), reason: 'no temporary file is left behind');
    },
  );
}
