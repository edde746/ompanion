import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/src/channel/attached_channel.dart';
import 'package:omp_core/src/host/scripts.dart';
import 'package:omp_core/src/transport/local_link.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

/// The command line dart:io hands CreateProcessW on Windows: the executable quoted when it holds a space and no
/// `"`, each argument quoted for the C runtime when it holds a space, a tab or a `"`, joined with spaces
/// (sdk/lib/_internal/vm/bin/process_patch.dart, `_ProcessImpl` and `_windowsArgumentEscape`;
/// runtime/bin/process_win.cc).
String dartWindowsCommandLine(({String executable, List<String> arguments}) start) {
  String escape(String argument) {
    if (argument.isEmpty) return '""';
    if (!argument.contains(RegExp('[\t "]'))) return argument;
    final quoted = argument.replaceAllMapped(RegExp(r'(\\*)"'), (m) => '${m[1]}${m[1]}\\"');
    return '"$quoted${RegExp(r'\\*$').firstMatch(argument)![0]}"';
  }

  final executable = start.executable;
  final path = executable.contains(' ') && !executable.contains('"') ? '"$executable"' : executable;
  return [path, ...start.arguments.map(escape)].join(' ');
}

/// What cmd.exe makes of [commandLine] (`cmd /?`): its switches, and the command after `/c`, of which `/s` removes
/// the first and the last quote. cmd.exe knows no `\"` escape.
({List<String> switches, String command}) cmdExe(String commandLine) {
  final match = RegExp(r'^cmd\.exe((?: /[^ ]+)*?) /c (.*)$', dotAll: true).firstMatch(commandLine)!;
  final switches = match[1]!.trim().split(' ');
  expect(switches, contains('/s'), reason: 'without /s cmd.exe may keep the quotes');
  var command = match[2]!;
  if (command.startsWith('"')) {
    final last = command.lastIndexOf('"');
    command = '${command.substring(1, last)}${command.substring(last + 1)}';
  }
  return (switches: switches, command: command);
}

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

  test('cmd.exe on Windows runs an exec command exactly as written', () {
    final commands = [
      windowsAttachedCommand(
        CommandShell.cmd,
        r'C:\Users\Jo Doe\demo',
        r'C:\Users\Jo Doe\AppData\Local\omp\omp.exe',
        ['--mode', 'rpc-ui', '-e', r'C:\Users\Jo Doe\.omp-app\companion\18.3.1\x.js', '--thinking', 'high'],
        r'C:\Users\Jo Doe\.omp-app\attached\OMPAPP_1.yml',
      ),
      powershellCommand(CommandShell.cmd, r'-File "C:\Users\Jo Doe\.omp-app\tmp\OMPAPP_2.ps1"'),
      'echo "OMPAPP_SHELL.%OS%.\$env:OS.\$OS."',
      r'dir C:\',
      'echo ok',
    ];
    for (final command in commands) {
      expect(cmdExe(dartWindowsCommandLine(windowsShellStart(command))).command, command);
    }
  });

  test('cmd.exe on Windows makes the directory at the backslashed path and no missing parents', () {
    final start = windowsMkdirStart('C:/Users/Jo Doe/100%OS%/.omp-app');
    final cmd = cmdExe(dartWindowsCommandLine((executable: start.executable, arguments: start.arguments)));
    expect(cmd.switches, contains('/e:off'), reason: 'command extensions make mkdir create parents');
    final expanded = cmd.command.replaceAllMapped(RegExp('%([^%]+)%'), (m) => start.environment[m[1]] ?? m[0]!);
    expect(expanded, r'mkdir "C:\Users\Jo Doe\100%OS%\.omp-app"', reason: 'cmd.exe expands a variable once');
  });

  test('concurrent mkdir admits exactly one locker', () async {
    final files = await link.files();
    final lock = '${await files.home()}/race.lock';
    final outcomes = await Future.wait(List.generate(8, (_) async {
      try {
        await files.mkdir(lock, mode: 0x1c0);
        return true;
      } on HostFileExists {
        return false;
      }
    }));
    expect(outcomes.where((won) => won), hasLength(1));
    expect((await files.stat(lock))!.mode! & 0x1ff, 0x1c0);
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

  test('rename moves directories like SFTP does', () async {
    final files = await link.files();
    final home = await files.home();
    await files.mkdir('$home/old');
    await files.write('$home/old/inside', utf8.encode('x'));
    await files.rename('$home/old', '$home/new');
    expect(await files.stat('$home/old'), isNull);
    expect(utf8.decode(await files.read('$home/new/inside')), 'x');
  });

  group('symbolic links', () {
    late HostFiles files;
    late String home;

    setUp(() async {
      files = await link.files();
      home = await files.home();
      await Directory('$home/target').create();
      await File('$home/target/keep').writeAsString('x');
      await Link('$home/tree/dir-link').create('$home/target', recursive: true);
      await Link('$home/tree/dangling').create('$home/gone');
      await Directory('$home/tree/real').create();
    });

    test('stat follows a link unless told not to', () async {
      expect((await files.stat('$home/tree/dir-link'))!.isDirectory, isTrue);
      final own = (await files.stat('$home/tree/dir-link', followLinks: false))!;
      expect((own.isLink, own.isDirectory), (true, false));
      expect(await files.stat('$home/tree/dangling'), isNull);
      expect((await files.stat('$home/tree/dangling', followLinks: false))!.isLink, isTrue);
      final real = (await files.stat('$home/tree/real', followLinks: false))!;
      expect((real.isLink, real.isDirectory), (false, true));
    });

    test('list reports links as links, not as what they point to', () async {
      final entries = {for (final entry in await files.list('$home/tree')) entry.name: entry.stat};
      expect((entries['dir-link']!.isLink, entries['dir-link']!.isDirectory), (true, false));
      expect(entries['dangling']!.isLink, isTrue);
      expect((entries['real']!.isLink, entries['real']!.isDirectory), (false, true));
    });

    test('remove deletes the link itself and leaves its target', () async {
      await files.remove('$home/tree/dir-link');
      await files.remove('$home/tree/dangling');
      expect(await files.list('$home/tree'), [isA<HostDirEntry>().having((entry) => entry.name, 'name', 'real')]);
      expect(await File('$home/target/keep').readAsString(), 'x');
    });
  });
}
