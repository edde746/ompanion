import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import 'fixtures.dart';


void main() {
  late Directory temp;
  late LocalLink link;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('install-');
    link = LocalLink(environment: {'HOME': temp.path});
  });

  tearDown(() async {
    await link.close();
    await temp.delete(recursive: true);
  });

  test('an uploaded binary with the wrong digest is rejected and removed, and the lock released', () async {
    final dir = '${temp.path}/bin';
    await expectLater(
      uploadOmp(link, macArm, '18.3.1', asset: Stream.value('not omp'.codeUnits), installDir: dir),
      throwsA(isA<HostLinkException>().having((e) => e.message, 'message', contains('SHA-256 mismatch'))),
    );
    expect(Directory(dir).listSync(), isEmpty);
    expect(Directory('${temp.path}/.omp-app/install.lock').existsSync(), isFalse);
  });

  test('the wget fallback refuses a download with the wrong digest', () async {
    // A PATH without curl, so the command takes its wget branch; wget "downloads" garbage.
    final tools = Directory('${temp.path}/tools')..createSync();
    for (final tool in ['cut', 'shasum']) {
      Link('${tools.path}/$tool').createSync('/usr/bin/$tool');
    }
    File('${tools.path}/wget')
      ..writeAsStringSync('#!/bin/sh\nprintf garbage > "\$2"\n')
      ..createSync();
    await Process.run('chmod', ['755', '${tools.path}/wget']);
    final dir = '${temp.path}/bin';
    final command = posixInstallCommand(macArm, '18.3.1', installDir: dir);
    final result = await Process.run('/bin/sh', ['-c', command], environment: {'PATH': '${tools.path}:/bin', 'HOME': temp.path});
    expect(result.exitCode, isNot(0));
    expect(File('$dir/omp').existsSync(), isFalse);
  });
}
