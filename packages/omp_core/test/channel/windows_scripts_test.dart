import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:omp_core/host.dart';
import 'package:omp_core/src/channel/windows_run.dart';
import 'package:omp_core/src/host/scripts.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

import '../host/fixtures.dart';

/// PowerShell 7, when installed, runs the Windows scripts that do not need Windows itself; Windows
/// PowerShell 5.1, cmd.exe and WMI are not available here.
final String? pwsh = () {
  final result = Process.runSync('/bin/sh', ['-c', 'command -v pwsh']);
  return result.exitCode == 0 ? (result.stdout as String).trim() : null;
}();

Future<ScriptResult> runPwsh(String script, Map<String, String> environment) async {
  final result = await Process.run(
    pwsh!,
    ['-NoProfile', '-NonInteractive', '-EncodedCommand', encodePowerShell('$powershellPreamble$script')],
    environment: environment,
  );
  return ScriptResult(result.stdout as String, result.stderr as String, HostExit(code: result.exitCode));
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
    expect(encodedPowerShellCommand(CommandShell.cmd, '$powershellPreamble${windowsProbeScript(newMarker())}'), isNotNull);
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
        environment: {'OMPAPP_RUN': run},
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
      const marker = 'OMPAPP_test';
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
      const marker = 'OMPAPP_test';
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
  });
}
