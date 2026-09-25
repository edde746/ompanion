import 'dart:convert';
import 'dart:io';

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

  test('the shell lock function breaks a stale lock and fails once its directory is gone', () async {
    await Directory('${temp.path}/run/in.lock').create(recursive: true);
    await Process.run('touch', ['-t', '202001010000', '${temp.path}/run/in.lock']);
    final taken = await runPosixScript(link, '$posixLockFunctions\nlock ${shQuote('${temp.path}/run/in.lock')} 30 && echo taken');
    expect(taken.stdout, 'taken\n');
    final gone = await runPosixScript(link, '$posixLockFunctions\nlock ${shQuote('${temp.path}/nope/in.lock')} 30 || echo failed');
    expect(gone.stdout, 'failed\n');
  });
}
