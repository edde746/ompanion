import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

void main() {
  group('shell probe', () {
    test('tells cmd.exe, PowerShell and POSIX shells apart, including a POSIX shell on Windows', () {
      expect(parseShellProbe('"OMPAPP_SHELL.Windows_NT.\$env:OS.\$OS."\r\n'), CommandShell.cmd);
      expect(parseShellProbe('OMPAPP_SHELL.%OS%.Windows_NT..\r\n'), CommandShell.powershell);
      expect(parseShellProbe('motd\nOMPAPP_SHELL.%OS%.:OS..\n'), CommandShell.posix);
      expect(parseShellProbe('OMPAPP_SHELL.%OS%.:OS.Windows_NT.\n'), CommandShell.posix);
      expect(parseShellProbe(''), CommandShell.posix, reason: 'csh fails on the unset variable and prints nothing');
    });

    test('a POSIX shell prints the probe as expected', () async {
      final result = await Process.run('/bin/sh', ['-c', shellProbeCommand]);
      expect(parseShellProbe(result.stdout as String), CommandShell.posix);
    });
  });

  group('POSIX probe', () {
    late Directory home;

    setUp(() async {
      home = await Directory.systemTemp.createTemp('probe home ');
      await Directory('${home.path}/.local/bin').create(recursive: true);
      final omp = File('${home.path}/.local/bin/omp');
      await omp.writeAsString('#!/bin/sh\necho "omp/18.3.1"\n');
      await Process.run('chmod', ['755', omp.path]);
    });

    tearDown(() => home.delete(recursive: true));

    Future<HostProbe> probe(Map<String, String> environment) async {
      final link = LocalLink(environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', ...environment});
      try {
        return await probeHost(link);
      } finally {
        await link.close();
      }
    }

    test('finds omp outside PATH and reports this machine', () async {
      final result = await probe({'PI_CODING_AGENT_DIR': '', 'OMP_PROFILE': ''});
      expect(result.commandShell, CommandShell.posix);
      expect(result.os, Platform.isMacOS ? HostOs.macos : HostOs.linux);
      expect(result.home, home.path);
      expect(result.agentDir, '${home.path}/.omp/agent');
      expect(result.ompPath, '${home.path}/.local/bin/omp');
      expect(result.ompVersion, '18.3.1');
      expect(result.curl, File('/usr/bin/curl').existsSync());
      if (Platform.isMacOS) expect(result.arch, anyOf('arm64', 'x64'));
    });

    test('honours PI_CODING_AGENT_DIR, and OMP_PROFILE over it', () async {
      expect((await probe({'PI_CODING_AGENT_DIR': '/elsewhere/agent', 'OMP_PROFILE': ''})).agentDir, '/elsewhere/agent');
      final profiled = await probe({'PI_CODING_AGENT_DIR': '/elsewhere/agent', 'OMP_PROFILE': 'work'});
      expect(profiled.agentDir, '${home.path}/.omp/profiles/work/agent');
      expect(profiled.profile, 'work');
    });

    test('an omp on PATH wins', () async {
      await Directory('${home.path}/bin').create();
      await File('${home.path}/.local/bin/omp').copy('${home.path}/bin/omp');
      final link = LocalLink(environment: {'HOME': home.path, 'PATH': '${home.path}/bin:/usr/bin:/bin'});
      addTearDown(link.close);
      expect((await probeHost(link)).ompPath, '${home.path}/bin/omp');
    });
  });

  test('POSIX probe payloads map to release assets', () {
    HostProbe parse(Map<String, String> fields) =>
        parsePosixProbe(jsonEncode({'v': '1', 'home': '/home/u', 'agentDir': '/home/u/.omp/agent', ...fields}));
    expect(parse({'kernel': 'Linux', 'machine': 'aarch64', 'libc': 'musl'}).releaseAsset, 'omp-linux-musl-arm64');
    expect(parse({'kernel': 'Linux', 'machine': 'x86_64', 'libc': 'glibc'}).releaseAsset, 'omp-linux-x64');
    expect(parse({'kernel': 'Darwin', 'machine': 'x86_64', 'arm64': '1'}).releaseAsset, 'omp-darwin-arm64',
        reason: 'uname -m under Rosetta says x86_64');
    expect(parse({'kernel': 'Linux', 'machine': 'riscv64', 'libc': 'glibc'}).releaseAsset, isNull);
    expect(parse({'kernel': 'MINGW64_NT-10.0-26100', 'machine': 'x86_64'}).os, HostOs.windows);
    expect(parse({'kernel': 'Linux', 'machine': 'x86_64', 'ompVersion': 'omp/18.3.1'}).ompVersion, '18.3.1');
    expect(() => parse({'kernel': 'Linux', 'home': ''}), throwsFormatException);
  });

  test('Windows probe payloads parse, WOW64 architecture included', () {
    final probe = parseWindowsProbe(
      r'{"v":"1","kernel":"Windows_NT","machine":"AMD64","shell":null,"home":"C:\\Users\\Jos\u00e9",'
      r'"agentDir":"C:\\Users\\Jos\u00e9\\.omp\\agent","profile":null,"omp":"C:\\Users\\Jos\u00e9\\AppData\\Local\\omp\\omp.exe",'
      r'"ompVersion":"omp/18.3.1","curl":"1","powershell":"5.1.26100.1","localAppData":"C:\\Users\\Jos\u00e9\\AppData\\Local","sshd":"9.5.0.0"}',
      CommandShell.cmd,
    );
    expect(probe.os, HostOs.windows);
    expect(probe.arch, 'x64');
    expect(probe.home, r'C:\Users\José');
    expect(probe.ompVersion, '18.3.1');
    expect(probe.releaseAsset, 'omp-windows-x64.exe');
    expect(probe.powershellVersion, '5.1.26100.1');
    expect(HostProbe.fromJson(probe.toJson()).toJson(), probe.toJson());
  });
}
