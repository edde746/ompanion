import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/src/host/scripts.dart' show encodePowerShell, powershellPreamble;
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

void main() {
  group('shell probe', () {
    test('tells cmd.exe, PowerShell and POSIX shells apart, including a POSIX shell on Windows', () {
      expect(parseShellProbe('"OMPANION_SHELL.Windows_NT.\$env:OS.\$OS."\r\n'), CommandShell.cmd);
      expect(parseShellProbe('OMPANION_SHELL.%OS%.Windows_NT..\r\n'), CommandShell.powershell);
      expect(parseShellProbe('motd\nOMPANION_SHELL.%OS%.:OS..\n'), CommandShell.posix);
      expect(parseShellProbe('OMPANION_SHELL.%OS%.:OS.Windows_NT.\n'), CommandShell.posix);
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

    Future<HostProbe> probe(Map<String, String> environment, {bool searchSystemPaths = true}) async {
      final link = LocalLink(environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', ...environment});
      try {
        return await probeHost(link, searchSystemPaths: searchSystemPaths);
      } finally {
        await link.close();
      }
    }

    Future<String> fakeOmp(String path, String version) async {
      await File(path).parent.create(recursive: true);
      await File(path).writeAsString('#!/bin/sh\necho "omp/$version"\n');
      await Process.run('chmod', ['755', path]);
      return path;
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
      expect(
        (await probe({'PI_CODING_AGENT_DIR': '/elsewhere/agent', 'OMP_PROFILE': ''})).agentDir,
        '/elsewhere/agent',
      );
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

    test('an omp on PATH older than the minimum gives way to the one in the install directory', () async {
      final old = await fakeOmp('${home.path}/bin/omp', '18.3.0');
      final result = await probe({'PATH': '${home.path}/bin:/usr/bin:/bin'});
      expect((result.ompPath, result.ompVersion), ('${home.path}/.local/bin/omp', '18.3.1'));
      await File('${home.path}/.local/bin/omp').delete();
      final only = await probe({'PATH': '${home.path}/bin:/usr/bin:/bin'}, searchSystemPaths: false);
      expect(only.ompPath, isNull, reason: 'PATH is not searched');
      await fakeOmp('${home.path}/.local/bin/omp', '18.2.0');
      final none = await probe({'PATH': '${home.path}/bin:/usr/bin:/bin'});
      expect(
        (none.ompPath, none.ompVersion),
        (old, '18.3.0'),
        reason: 'no usable omp: the first one found is reported',
      );
    });

    test('without system paths omp is looked for only in the home directory', () async {
      final system = await Directory.systemTemp.createTemp('probe system ');
      addTearDown(() => system.delete(recursive: true));
      final onPath = await fakeOmp('${system.path}/bin/omp', '18.4.0');
      await fakeOmp('${home.path}/.local/bin/omp', '18.0.0');
      final environment = {'PATH': '${system.path}/bin:/usr/bin:/bin'};
      expect((await probe(environment)).ompPath, onPath);
      final isolated = await probe(environment, searchSystemPaths: false);
      expect((isolated.ompPath, isolated.ompVersion), ('${home.path}/.local/bin/omp', '18.0.0'));
      await File('${home.path}/.local/bin/omp').delete();
      final bun = await fakeOmp('${home.path}/.bun/bin/omp', '18.3.1');
      expect((await probe(environment, searchSystemPaths: false)).ompPath, bun);
      await File(bun).delete();
      // omp in /opt/homebrew/bin or /usr/local/bin, as on this computer, is never looked at either.
      expect((await probe(environment, searchSystemPaths: false)).ompPath, isNull);
    });
  });

  group('login shell PATH', () {
    late Directory temp;

    setUp(() async => temp = await Directory.systemTemp.createTemp('probe login '));
    tearDown(() => temp.delete(recursive: true));

    /// A stand-in login shell: the flags land in `$flags`, then [body] runs with the command to run as `$1`.
    Future<String> fakeShell(String body) async {
      final path = '${temp.path}/shell';
      await File(path).writeAsString('#!/bin/sh\nflags=\$*\nwhile [ \$# -gt 1 ]; do shift; done\n$body\n');
      await Process.run('chmod', ['755', path]);
      return path;
    }

    /// Runs the real probe script with [shell] as the machine's login shell. [loginWait] is the probe's own
    /// budget in tenths of a second, kept short so a hanging shell test stays fast.
    Future<HostProbe> run(String shell, {int loginWait = 20}) async {
      final link = LocalLink(environment: {'HOME': temp.path, 'PATH': '/usr/bin:/bin', 'SHELL': shell});
      addTearDown(link.close);
      final marker = newMarker();
      final result = await runPosixScript(
        link,
        posixProbeScript(marker, searchSystemPaths: false, loginWait: loginWait),
      );
      return parsePosixProbe(result.payload(marker));
    }

    test('reads the PATH the login shell gives its children, past rc noise', () async {
      final shell = await fakeShell(
        'echo "welcome to my shell"\n'
        'PATH=/opt/homebrew/bin:/home/me/.local/bin:/usr/bin\n'
        'export PATH\n'
        r'eval "$1"'
        '\n'
        'echo "prompt %"',
      );
      final probe = await run(shell);
      expect(probe.loginPath, '/opt/homebrew/bin:/home/me/.local/bin:/usr/bin');
      expect(probe.loginProblem, isNull);
    });

    test('a shell that refuses -i still answers as a login shell', () async {
      final shell = await fakeShell(
        r'case $flags in *-i*) echo "illegal option -- i" >&2; exit 2;; esac'
        '\n'
        'PATH=/from-login-shell:/usr/bin\n'
        'export PATH\n'
        r'eval "$1"',
      );
      expect((await run(shell)).loginPath, '/from-login-shell:/usr/bin');
    });

    test('a shell that answers nothing leaves the exec PATH and says why', () async {
      final quiet = await run(await fakeShell(':'));
      expect(quiet.loginPath, isNull);
      expect(quiet.loginProblem, 'the login shell reported no PATH');
    });

    test('a shell that hangs is killed after the wait, and the probe returns', () async {
      final started = DateTime.now();
      final stuck = await run(await fakeShell('while :; do sleep 0.1; done'), loginWait: 2);
      expect(stuck.loginPath, isNull);
      expect(stuck.loginProblem, 'the login shell reported no PATH');
      expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
    });

    test(r'an empty $SHELL falls back to the account login shell from passwd', () async {
      final probe = await run('');
      expect(probe.loginPath, contains('/usr/bin'));
    });
  });

  test('POSIX probe payloads map to release assets', () {
    HostProbe parse(Map<String, Object> fields) => parsePosixProbe(
      jsonEncode({'v': '1', 'home': '/home/u', 'agentDir': '/home/u/.omp/agent', 'omps': <Object>[], ...fields}),
    );
    expect(parse({'kernel': 'Linux', 'machine': 'aarch64', 'libc': 'musl'}).releaseAsset, 'omp-linux-musl-arm64');
    expect(parse({'kernel': 'Linux', 'machine': 'x86_64', 'libc': 'glibc'}).releaseAsset, 'omp-linux-x64');
    expect(
      parse({'kernel': 'Darwin', 'machine': 'x86_64', 'arm64': '1'}).releaseAsset,
      'omp-darwin-arm64',
      reason: 'uname -m under Rosetta says x86_64',
    );
    expect(parse({'kernel': 'Linux', 'machine': 'riscv64', 'libc': 'glibc'}).releaseAsset, isNull);
    expect(parse({'kernel': 'MINGW64_NT-10.0-26100', 'machine': 'x86_64'}).os, HostOs.windows);
    expect(() => parse({'kernel': 'Linux', 'home': ''}), throwsFormatException);
  });

  test('the probe drives the first omp found that is new enough, else reports the first one', () {
    (String?, String?) pick(List<(String, String)> omps) {
      final probe = parsePosixProbe(
        jsonEncode({
          'v': '1',
          'kernel': 'Linux',
          'home': '/home/u',
          'agentDir': '/home/u/.omp/agent',
          'omps': [
            for (final (path, version) in omps) {'path': path, 'version': version},
          ],
        }),
      );
      return (probe.ompPath, probe.ompVersion);
    }

    expect(pick([('/usr/bin/omp', 'omp/18.3.1'), ('/home/u/.local/bin/omp', 'omp/19.0.0')]), (
      '/usr/bin/omp',
      '18.3.1',
    ));
    expect(pick([('/usr/bin/omp', 'omp/18.3.0'), ('/home/u/.local/bin/omp', 'omp/18.3.1')]), (
      '/home/u/.local/bin/omp',
      '18.3.1',
    ));
    expect(pick([('/usr/bin/omp', 'omp/18.3.1-rc.1'), ('/home/u/.local/bin/omp', 'omp/18.3.1')]), (
      '/home/u/.local/bin/omp',
      '18.3.1',
    ));
    expect(pick([('/usr/bin/omp', ''), ('/home/u/.local/bin/omp', 'omp/18.0.0')]), ('/usr/bin/omp', null));
    expect(pick([]), (null, null));
  });

  test('Windows probe payloads parse, WOW64 architecture included', () {
    final probe = parseWindowsProbe(
      r'{"v":"1","kernel":"Windows_NT","machine":"AMD64","shell":null,"home":"C:\\Users\\Jos\u00e9",'
      r'"agentDir":"C:\\Users\\Jos\u00e9\\.omp\\agent","profile":null,'
      r'"omps":[{"path":"C:\\Program Files\\omp\\omp.exe","version":null},{"path":"C:\\Users\\Jos\u00e9\\AppData\\Local\\omp\\omp.exe","version":"omp/18.3.1"}],'
      r'"curl":"1","powershell":"5.1.26100.1","localAppData":"C:\\Users\\Jos\u00e9\\AppData\\Local","sshd":"9.5.0.0"}',
      CommandShell.cmd,
    );
    expect(probe.os, HostOs.windows);
    expect(probe.arch, 'x64');
    expect(probe.home, r'C:\Users\José');
    expect((probe.ompPath, probe.ompVersion), (r'C:\Users\José\AppData\Local\omp\omp.exe', '18.3.1'));
    expect(probe.releaseAsset, 'omp-windows-x64.exe');
    expect(probe.powershellVersion, '5.1.26100.1');
    expect(HostProbe.fromJson(probe.toJson()).toJson(), probe.toJson());
  });

  group('Windows probe script', skip: _pwsh == null ? 'pwsh is not installed' : null, () {
    late Directory temp;

    setUp(() async => temp = await Directory.systemTemp.createTemp('windows probe '));

    tearDown(() => temp.delete(recursive: true));

    Future<HostProbe> probe({required String path, bool searchSystemPaths = true}) async {
      const marker = 'OMPANION_test';
      final profile = '${temp.path}/Users/me';
      final script = '$powershellPreamble${windowsProbeScript(marker, searchSystemPaths: searchSystemPaths)}';
      final result = await Process.run(
        _pwsh!,
        ['-NoProfile', '-NonInteractive', '-EncodedCommand', encodePowerShell(script)],
        environment: {
          'PATH': path,
          'USERPROFILE': profile,
          'LOCALAPPDATA': '$profile/AppData/Local',
          'SystemRoot': '${temp.path}/Windows',
          'ProgramFiles': '${temp.path}/Program Files',
          'PI_INSTALL_DIR': '',
        },
      );
      expect(result.exitCode, 0, reason: '${result.stderr}');
      return parseWindowsProbe(
        ScriptResult('${result.stdout}', '', const HostExit(code: 0)).payload(marker),
        CommandShell.powershell,
      );
    }

    Future<String> fakeOmp(String path, String version) async {
      await File(path).parent.create(recursive: true);
      await File(path).writeAsString('#!/bin/sh\necho "omp/$version"\n');
      await Process.run('chmod', ['755', path]);
      return path;
    }

    test(
      'an omp on PATH older than the minimum gives way to the one in LOCALAPPDATA, and PATH can be left out',
      () async {
        final bin = '${temp.path}/bin';
        final onPath = await fakeOmp('$bin/omp.exe', '18.3.0');
        final installed = await fakeOmp('${temp.path}/Users/me/AppData/Local/omp/omp.exe', '18.3.1');
        final path = '$bin:/usr/bin:/bin';
        final found = await probe(path: path);
        expect((found.ompPath, found.ompVersion), (installed, '18.3.1'));
        await File(installed).delete();
        expect((await probe(path: path)).ompPath, onPath, reason: 'no usable omp: the first one found is reported');
        expect((await probe(path: path, searchSystemPaths: false)).ompPath, isNull);
      },
    );
  });
}

final String? _pwsh = () {
  final result = Process.runSync('/bin/sh', ['-c', 'command -v pwsh']);
  return result.exitCode == 0 ? (result.stdout as String).trim() : null;
}();
