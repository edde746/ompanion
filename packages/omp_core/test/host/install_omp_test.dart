@Tags(['omp'])
library;

import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../omp_binary.dart';

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
    final installed = await uploadOmp(link, thisComputer, '18.3.1', asset: File(ompBinary).openRead(), installDir: dir);
    expect(installed, '$dir/omp');
    final version = await Process.run(installed, ['--version'], environment: {'HOME': temp.path});
    expect((version.stdout as String).trim(), 'omp/18.3.1');
    expect(Directory(dir).listSync().map((e) => e.path), ['$dir/omp']);
  });

  test('the install script, run as one command line (the manual route), downloads, checks and installs omp', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      final response = request.response..contentLength = File(ompBinary).lengthSync();
      await response.addStream(File(ompBinary).openRead());
      await response.close();
    });
    final dir = '${temp.path}/bin';
    final script = posixInstallCommand(
      thisComputer,
      '18.3.1',
      installDir: dir,
      assetBase: Uri.parse('http://127.0.0.1:${server.port}/'),
    );
    final result = await Process.run('/bin/sh', ['-c', script], environment: {'HOME': temp.path});
    expect(result.exitCode, 0, reason: '${result.stderr}');
    final version = await Process.run('$dir/omp', ['--version'], environment: {'HOME': temp.path});
    expect((version.stdout as String).trim(), 'omp/18.3.1');
    expect(Directory(dir).listSync().map((e) => e.path), ['$dir/omp']);
  });
}
