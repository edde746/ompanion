import 'dart:io';
import 'dart:typed_data';

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
    expect(Directory('${temp.path}/.ompanion/install.lock').existsSync(), isFalse);
  });

  test('an interrupted upload leaves no partial file, and a retry takes over the lock a dropped link left', () async {
    final dir = '${temp.path}/bin';
    final lock = '${temp.path}/.ompanion/install.lock';
    Stream<List<int>> cut(void Function() fail) async* {
      yield Uint8List(5 << 20);
      fail();
      yield Uint8List(5 << 20);
    }

    // The download fails midway while the link is up: the partial file goes and the lock is released.
    await expectLater(
      uploadOmp(link, macArm, '18.3.1', asset: cut(() => throw const HttpException('reset')), installDir: dir),
      throwsA(isA<HttpException>()),
    );
    expect(Directory(dir).listSync(), isEmpty);
    expect(Directory(lock).existsSync(), isFalse);

    // The link drops midway: nothing can be cleaned up, and the lock stays behind.
    final dropping = _DroppingLink(LocalLink(environment: {'HOME': temp.path}));
    await expectLater(
      uploadOmp(dropping, macArm, '18.3.1', asset: cut(() => dropping.dropped = true), installDir: dir),
      throwsA(isA<HostLinkException>()),
    );
    expect(Directory(dir).listSync(), hasLength(1));
    expect(Directory(lock).existsSync(), isTrue);

    // Reconnected, the next install takes that lock over at once and removes the partial upload.
    await expectLater(
      uploadOmp(
        link,
        macArm,
        '18.3.1',
        asset: Stream.value('not omp'.codeUnits),
        installDir: dir,
        lockTimeout: Duration.zero,
      ),
      throwsA(isA<HostLinkException>().having((e) => e.message, 'message', contains('SHA-256 mismatch'))),
    );
    expect(Directory(dir).listSync(), isEmpty);
    expect(Directory(lock).existsSync(), isFalse);
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

/// This computer until [dropped] is set; from then on every file operation fails, as over an SSH link that went away.
final class _DroppingLink implements HostLink {
  _DroppingLink(this._inner);

  final LocalLink _inner;
  bool dropped = false;

  void check() {
    if (dropped) throw HostLinkException('the link dropped');
  }

  @override
  String get label => _inner.label;

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) async {
    check();
    return _inner.exec(command, pty: pty);
  }

  @override
  Future<HostFiles> files() async {
    check();
    return _DroppingFiles(this, await _inner.files());
  }

  @override
  Future<HostSocket> connect(String host, int port) => _inner.connect(host, port);

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();
}

final class _DroppingFiles implements HostFiles {
  _DroppingFiles(this._link, this._inner);

  final _DroppingLink _link;
  final HostFiles _inner;

  Future<T> _run<T>(Future<T> Function() operation) async {
    _link.check();
    return operation();
  }

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) =>
      _run(() => _inner.stat(path, followLinks: followLinks));

  @override
  Future<List<HostDirEntry>> list(String path) => _run(() => _inner.list(path));

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) =>
      _run(() => _inner.read(path, offset: offset, length: length));

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) =>
      _run(() => _inner.write(path, bytes, append: append, mode: mode));

  @override
  Future<void> mkdir(String path, {int? mode}) => _run(() => _inner.mkdir(path, mode: mode));

  @override
  Future<void> remove(String path) => _run(() => _inner.remove(path));

  @override
  Future<void> removeDir(String path) => _run(() => _inner.removeDir(path));

  @override
  Future<void> rename(String from, String to) => _run(() => _inner.rename(from, to));

  @override
  Future<String> home() => _run(_inner.home);

  @override
  Future<void> close() => _inner.close();
}
