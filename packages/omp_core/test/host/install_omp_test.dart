@Tags(['omp'])
library;

import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../channel/support.dart';
import 'fixtures.dart';

void main() {
  late Directory temp;
  late LocalLink link;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('install omp ');
    link = LocalLink(environment: {'HOME': temp.path});
  });

  tearDown(() async {
    await link.close();
    await temp.delete(recursive: true);
  });

  test('uploading the release asset installs a working omp', () async {
    final dir = '${temp.path}/bin';
    final installed = await uploadOmp(link, macArm, '18.3.1', asset: File(ompBinary).openRead(), installDir: dir);
    expect(installed, '$dir/omp');
    final version = await Process.run(installed, ['--version'], environment: {'HOME': temp.path});
    expect((version.stdout as String).trim(), 'omp/18.3.1');
    expect(Directory(dir).listSync().map((e) => e.path), ['$dir/omp']);
  });

  test('the wget fallback installs a download whose digest matches', () async {
    final tools = Directory('${temp.path}/tools')..createSync();
    for (final tool in ['cut', 'shasum']) {
      Link('${tools.path}/$tool').createSync('/usr/bin/$tool');
    }
    File('${tools.path}/wget').writeAsStringSync('#!/bin/sh\ncp "$ompBinary" "\$2"\n');
    await Process.run('chmod', ['755', '${tools.path}/wget']);
    final dir = '${temp.path}/bin';
    final result = await Process.run(
      '/bin/sh',
      ['-c', posixInstallCommand(macArm, '18.3.1', installDir: dir)],
      environment: {'PATH': '${tools.path}:/bin', 'HOME': temp.path},
    );
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final version = await Process.run('$dir/omp', ['--version'], environment: {'HOME': temp.path});
    expect((version.stdout as String).trim(), 'omp/18.3.1');
  });
}
