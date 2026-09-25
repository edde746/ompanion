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

  test('the install script refuses a tampered download before running it and removes it', () async {
    // It would print the expected version, so only the digest check stands between it and the target.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final requested = <String>[];
    server.listen((request) {
      requested.add(request.uri.path);
      request.response
        ..write('#!/bin/sh\ntouch "${temp.path}/ran"\necho omp/18.3.1\n')
        ..close();
    });
    final dir = '${temp.path}/bin';
    final script = posixInstallCommand(
      macArm,
      '18.3.1',
      installDir: dir,
      assetBase: Uri.parse('http://127.0.0.1:${server.port}/v18.3.1/'),
    );
    final result = await runPosixScript(link, script);
    expect(result.exit.code, 1);
    expect(result.stderr, contains('SHA-256 mismatch'));
    expect(requested, ['/v18.3.1/omp-darwin-arm64']);
    expect(Directory(dir).listSync(), isEmpty);
    expect(File('${temp.path}/ran').existsSync(), isFalse);
  });
}
