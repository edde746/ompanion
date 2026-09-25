import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/src/host/scripts.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

void main() {
  late Directory temp;
  late LocalLink link;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('scripts-');
    link = LocalLink(environment: {'HOME': temp.path});
  });

  tearDown(() async {
    await link.close();
    await temp.delete(recursive: true);
  });

  test('shQuote makes any value one sh word', () async {
    const values = ['plain', "it's", 'a  b', r'$HOME `id` \n \\', 'two\nlines', 'é ✓ 🎉', "''", '-n', ''];
    for (final value in values) {
      final result = await runPosixScript(link, 'printf %s ${shQuote(value)}');
      expect(result.stdout, value);
    }
  });

  test('a started script reads the stdin that follows it, even when it arrives in the same write', () async {
    final process = await startPosixScript(link, 'while IFS= read -r l; do echo "got:\$l"; done\necho end');
    process.write(utf8.encode('one\ntwo\n'));
    await process.closeStdin();
    expect(await utf8.decodeStream(process.stdout), 'got:one\ngot:two\nend\n');
  });

  test('the payload is found between its markers, whatever the shell printed around it', () {
    const result = ScriptResult('Last login: today\nOMPAPP_1:begin\n{"a":1}\nOMPAPP_1:end\nbye\n', '', HostExit(code: 0));
    expect(result.payload('OMPAPP_1'), '{"a":1}');
    expect(() => result.payload('OMPAPP_2'), throwsA(isA<HostLinkException>()));
  });

  test('encodePowerShell is base64 of UTF-16LE, surrogate pairs included', () {
    expect(encodePowerShell('a'), 'YQA=');
    expect(base64.decode(encodePowerShell('€🎉')), [0xAC, 0x20, 0x3C, 0xD8, 0x89, 0xDF]);
  });

  test('an encoded command that would not fit on a cmd.exe line is refused', () {
    var size = 0;
    while (encodedPowerShellCommand(CommandShell.cmd, 'x' * (size + 1)) != null) {
      size++;
    }
    expect(encodedPowerShellCommand(CommandShell.cmd, 'x' * size)!.length, lessThanOrEqualTo(windowsCommandLineLimit));
    final over = powershellCommand(CommandShell.cmd, '-EncodedCommand ${encodePowerShell('x' * (size + 1))}');
    expect(over.length, greaterThan(windowsCommandLineLimit));
  });

  test('a mkdir lock waits for its holder and breaks a lock left by a dead one', () async {
    final files = await link.files();
    final lock = '${temp.path}/x.lock';
    await acquireDirLock(files, lock, timeout: const Duration(seconds: 1), stale: const Duration(minutes: 1));
    await expectLater(
      acquireDirLock(files, lock, timeout: const Duration(milliseconds: 300), stale: const Duration(minutes: 1)),
      throwsA(isA<HostLinkException>()),
    );
    await Process.run('touch', ['-t', '202001010000', lock]);
    await acquireDirLock(files, lock, timeout: const Duration(seconds: 1), stale: const Duration(minutes: 1));
    expect(Directory(lock).statSync().modified.year, DateTime.now().year, reason: 'the stale lock was replaced');
  });

  test("a mkdir lock's age is taken on the host's clock, whichever way this device's is off", () async {
    final lock = '${temp.path}/in.lock';
    // The host runs ten minutes behind: its fresh lock looks ten minutes old from here, and is still held.
    final behind = _SkewedFiles(await link.files(), const Duration(minutes: -10));
    await acquireDirLock(behind, lock, timeout: const Duration(seconds: 1), stale: const Duration(minutes: 1));
    await expectLater(
      acquireDirLock(behind, lock, timeout: const Duration(milliseconds: 300), stale: const Duration(minutes: 1)),
      throwsA(isA<HostLinkException>()),
    );
    // The host runs ten minutes ahead: a lock its dead holder took two minutes ago looks eight minutes young.
    final ahead = _SkewedFiles(await link.files(), const Duration(minutes: 10));
    final twoMinutesAgo = DateTime.now().subtract(const Duration(minutes: 2));
    await Process.run('touch', ['-t', _touchTime(twoMinutesAgo), lock]);
    await acquireDirLock(ahead, lock, timeout: const Duration(seconds: 1), stale: const Duration(minutes: 1));
    expect(Directory(lock).statSync().modified.isAfter(twoMinutesAgo.add(const Duration(minutes: 1))), isTrue,
        reason: 'the stale lock was replaced');
    expect(Directory(temp.path).listSync().map((e) => e.path), [lock], reason: 'the clock file is gone');
  });

  test('the shell lock function breaks a stale lock and fails once its directory is gone', () async {
    await Directory('${temp.path}/run/in.lock').create(recursive: true);
    await Process.run('touch', ['-t', '202001010000', '${temp.path}/run/in.lock']);
    final taken = await runPosixScript(link, '$posixLockFunctions\nlock ${shQuote('${temp.path}/run/in.lock')} 30 && echo taken');
    expect(taken.stdout, 'taken\n');
    final gone = await runPosixScript(link, '$posixLockFunctions\nlock ${shQuote('${temp.path}/nope/in.lock')} 30 || echo failed');
    expect(gone.stdout, 'failed\n');
    expect(gone.stderr, contains('no directory ${temp.path}/nope'));
  });

  test('the shell lock function fails when mkdir fails for a reason other than a held lock', () async {
    // A name longer than any file system takes stands in for a full disk or a read-only directory, whatever the user.
    final lock = '${temp.path}/${'x' * 300}';
    final result = await runPosixScript(link, '$posixLockFunctions\nlock ${shQuote(lock)} 1 || echo failed')
        .timeout(const Duration(seconds: 10));
    expect(result.stdout, 'failed\n');
    expect(result.stderr, contains('too long'), reason: "mkdir's own reason");
  });

  test('the shell lock function gives up on a lock it cannot break after four times the stale age', () async {
    final lock = Directory('${temp.path}/in.lock')..createSync();
    File('${lock.path}/stray').createSync();
    await Process.run('touch', ['-t', '202001010000', lock.path]);
    final watch = Stopwatch()..start();
    final result = await runPosixScript(link, '$posixLockFunctions\nlock ${shQuote(lock.path)} 1 || echo failed')
        .timeout(const Duration(seconds: 20));
    expect(result.stdout, 'failed\n');
    expect(result.stderr, contains('is still held'));
    expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 4)));
  });
}

String _touchTime(DateTime time) =>
    '${time.year}${[time.month, time.day, time.hour, time.minute].map((v) => '$v'.padLeft(2, '0')).join()}.'
    '${'${time.second}'.padLeft(2, '0')}';

/// A machine whose clock is [_skew] off this device's: every modification time it reports is shifted.
final class _SkewedFiles implements HostFiles {
  _SkewedFiles(this._inner, this._skew);

  final HostFiles _inner;
  final Duration _skew;

  HostFileStat _shift(HostFileStat stat) => HostFileStat(
    size: stat.size,
    isDirectory: stat.isDirectory,
    isLink: stat.isLink,
    modified: stat.modified?.add(_skew),
    mode: stat.mode,
  );

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) async {
    final stat = await _inner.stat(path, followLinks: followLinks);
    return stat == null ? null : _shift(stat);
  }

  @override
  Future<List<HostDirEntry>> list(String path) async =>
      [for (final entry in await _inner.list(path)) HostDirEntry(entry.name, _shift(entry.stat))];

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) => _inner.read(path, offset: offset, length: length);

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) =>
      _inner.write(path, bytes, append: append, mode: mode);

  @override
  Future<void> mkdir(String path, {int? mode}) => _inner.mkdir(path, mode: mode);

  @override
  Future<void> remove(String path) => _inner.remove(path);

  @override
  Future<void> removeDir(String path) => _inner.removeDir(path);

  @override
  Future<void> rename(String from, String to) => _inner.rename(from, to);

  @override
  Future<String> home() => _inner.home();

  @override
  Future<void> close() => _inner.close();
}
