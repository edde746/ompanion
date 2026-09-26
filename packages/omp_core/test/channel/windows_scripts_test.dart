import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/host.dart';
import 'package:omp_core/src/channel/windows_channel.dart' show windowsAppenderScript;
import 'package:omp_core/src/channel/windows_run.dart';
import 'package:omp_core/src/host/scripts.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../host/fixtures.dart';
import 'support.dart';

Future<ScriptResult> runPwsh(String script, Map<String, String> environment) async {
  final result = await Process.run(pwsh!, [
    '-NoProfile',
    '-NonInteractive',
    '-EncodedCommand',
    encodePowerShell('$powershellPreamble$script'),
  ], environment: environment);
  return ScriptResult(result.stdout as String, result.stderr as String, HostExit(code: result.exitCode));
}

/// A machine whose login shell is [_shell]: it parses every exec command, as sshd's `$SHELL -c` does.
final class _LoginShellLink implements HostLink {
  _LoginShellLink(this._local, this._shell);

  final LocalLink _local;
  final String _shell;

  @override
  String get label => _local.label;

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) =>
      _local.exec('exec $_shell -c ${shQuote(command)}', pty: pty);

  @override
  Future<HostFiles> files() => _local.files();

  @override
  Future<HostSocket> connect(String host, int port) => _local.connect(host, port);

  @override
  Future<void> get done => _local.done;

  @override
  Future<void> close() => _local.close();
}

void main() {
  test('Windows arguments are quoted for CommandLineToArgvW and refused when cmd.exe would misread them', () {
    expect(windowsArg('--mode'), '--mode');
    expect(windowsArg('fake/fake-1'), 'fake/fake-1');
    expect(windowsArg(r'C:\Users\José\a b.jsonl'), r'"C:\Users\José\a b.jsonl"');
    expect(windowsArg(r'C:\dir\'), r'"C:\dir\\"', reason: 'a trailing backslash would escape the closing quote');
    expect(windowsArg('a&b'), '"a&b"');
    expect(windowsArg(''), '""');
    expect(() => windowsArg('say "hi"'), throwsArgumentError);
  });

  test('the Windows probe fits on one cmd.exe line, so first contact needs no SFTP', () {
    expect(
      encodedPowerShellCommand(CommandShell.cmd, '$powershellPreamble${windowsProbeScript(newMarker())}'),
      isNotNull,
    );
  });

  test('the in.jsonl appender fits on one cmd.exe line, so it can keep stdin for the lines', () {
    final dir = '${r'C:\Users\'}${'é' * 200}${r'\.ompanion\run\20260926T121807-195ca655'}';
    expect(encodedPowerShellCommand(CommandShell.cmd, '$powershellPreamble${windowsAppenderScript(dir)}'), isNotNull);
  });

  group('with PowerShell 7', skip: pwsh == null ? 'pwsh is not installed' : null, () {
    late Directory temp;

    setUp(() async => temp = await Directory.systemTemp.createTemp('windows scripts '));

    tearDown(() => temp.delete(recursive: true));

    test('feed.ps1 copies in.jsonl byte for byte and exits once the stop file exists', () async {
      final run = temp.path;
      await File('$run/feed.ps1').writeAsString(windowsFeedScript);
      final input = File('$run/in.jsonl')..writeAsStringSync('{"id":"1"}\n');
      final feed = await Process.start(
        pwsh!,
        ['-NoProfile', '-NonInteractive', '-File', '$run/feed.ps1'],
        environment: {'OMPANION_RUN': run},
      );
      final out = BytesBuilder();
      final copied = feed.stdout.forEach(out.add);
      final errors = utf8.decodeStream(feed.stderr);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      input.writeAsStringSync('{"t":"é ✓"}\r\n', mode: FileMode.append, flush: true);
      input.writeAsStringSync('${jsonEncode({'big': 'x' * 200000})}\n', mode: FileMode.append, flush: true);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      File('$run/in.jsonl.stop').createSync();
      expect(await feed.exitCode.timeout(const Duration(seconds: 10)), 0, reason: await errors);
      await copied;
      expect(out.takeBytes(), input.readAsBytesSync());
    });

    test('the session listing script finds what the POSIX one finds', () async {
      final home = '${temp.path}/home';
      await writeSessionFixtures(home, temp.path);
      const marker = 'OMPANION_test';
      final result = await runPwsh(windowsSessionListScript(marker, ['${temp.path}/session dir']), {
        'USERPROFILE': home,
        'PI_CODING_AGENT_DIR': '${temp.path}/custom agent',
        'PI_CONFIG_DIR': '',
      });
      expect(result.exit.code, 0, reason: result.stderr);
      expectFixtureSessions(parseSessionList(result.payload(marker)), '$home/.omp/agent/sessions');
    });

    test('the probe script reads the architecture under WOW64 and finds omp in LOCALAPPDATA', () async {
      final profile = '${temp.path}/Users/José';
      final local = '$profile/AppData/Local';
      final omp = File('$local/omp/omp.exe');
      await omp.parent.create(recursive: true);
      await omp.writeAsString('#!/bin/sh\necho "omp/18.3.1"\n');
      await Process.run('chmod', ['755', omp.path]);
      const marker = 'OMPANION_test';
      final result = await runPwsh(windowsProbeScript(marker), {
        'USERPROFILE': profile,
        'LOCALAPPDATA': local,
        'PROCESSOR_ARCHITECTURE': 'x86',
        'PROCESSOR_ARCHITEW6432': 'ARM64',
        'SystemRoot': '${temp.path}/Windows',
        'ProgramFiles': '${temp.path}/Program Files',
        'PI_CODING_AGENT_DIR': '',
        'OMP_PROFILE': '',
        'PI_PROFILE': '',
        'PI_CONFIG_DIR': '',
        'PI_INSTALL_DIR': '',
      });
      expect(result.exit.code, 0, reason: result.stderr);
      final probe = parseWindowsProbe(result.payload(marker), CommandShell.powershell);
      expect(probe.arch, 'arm64');
      expect(probe.home, profile);
      expect(probe.ompPath, omp.path);
      expect(probe.ompVersion, '18.3.1');
      expect(probe.releaseAsset, 'omp-windows-arm64.exe');
      expect(probe.shell, isNull);
    });

    test('the install script refuses a tampered download and removes it, also pasted without the preamble', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen(
        (request) => request.response
          ..write('not omp')
          ..close(),
      );
      const windows = HostProbe(
        commandShell: CommandShell.powershell,
        os: HostOs.windows,
        kernel: 'Windows_NT',
        arch: 'x64',
        home: '/unused',
        agentDir: '/unused',
      );
      final dir = '${temp.path}/omp';
      final script = windowsInstallCommand(
        windows,
        '18.3.1',
        installDir: dir,
        assetBase: Uri.parse('http://127.0.0.1:${server.port}/'),
      );
      final result = await Process.run(pwsh!, ['-NoProfile', '-NonInteractive', '-Command', script]);
      expect(result.exitCode, isNot(0));
      expect('${result.stderr}', contains('SHA-256 mismatch'));
      expect(Directory(dir).listSync(), isEmpty);
    });

    test(
      'a script too long for one command line runs from a file whose path never reaches a POSIX login shell',
      () async {
        // csh stands in for login shells that misread sh quoting (fish, csh): a newline inside '…' is an error there.
        final home = Directory('${temp.path}/home\nwith a newline')..createSync();
        final bin = Directory('${temp.path}/bin')..createSync();
        Link('${bin.path}/powershell.exe').createSync(pwsh!);
        final link = _LoginShellLink(
          LocalLink(environment: {'HOME': home.path, 'PATH': '${bin.path}:/usr/bin:/bin'}),
          '/bin/csh',
        );
        final script = "# ${'x' * windowsCommandLineLimit}\n[Console]::Out.Write('ran')";
        expect(encodedPowerShellCommand(CommandShell.posix, '$powershellPreamble$script'), isNull);
        final result = await runPowerShell(link, CommandShell.posix, script);
        expect(result.exit.code, 0, reason: result.stderr);
        expect(result.stdout, 'ran');
        expect(Directory('${home.path}/.ompanion/tmp').listSync(), isEmpty, reason: 'the uploaded script is removed');
      },
    );
  });
}
