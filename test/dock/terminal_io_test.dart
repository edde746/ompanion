import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/terminal/shell_launch.dart';
import 'package:omp_core/host.dart';

void main() {
  group('input', () {
    test('keystrokes, control characters and pastes are UTF-8 bytes', () {
      expect(encodeTerminalInput('ls\r'), [0x6c, 0x73, 0x0d]);
      expect(encodeTerminalInput('\x03'), [0x03]);
      expect(encodeTerminalInput('\x1b[A'), [0x1b, 0x5b, 0x41]);
      expect(encodeTerminalInput('é🙂'), utf8.encode('é🙂'));
    });
  });

  group('output', () {
    test('a character split across chunks comes out whole', () {
      final text = <String>[];
      final decoder = TerminalOutputDecoder(text.add);
      final bytes = utf8.encode('a🙂b');
      for (final byte in bytes) {
        decoder.add([byte]);
      }
      decoder.close();
      expect(text.join(), 'a🙂b');
      expect(text, isNot(contains(contains('\u{fffd}'))));
    });

    test('invalid bytes become replacement characters instead of ending the stream', () {
      final text = <String>[];
      final decoder = TerminalOutputDecoder(text.add);
      decoder
        ..add([0x61, 0xff, 0x62])
        ..add(utf8.encode('ok'))
        ..add([0xe2, 0x82]);
      decoder.close();
      expect(text.join(), 'a\u{fffd}bok\u{fffd}');
    });
  });

  group('remote shell command', () {
    test('POSIX: the login shell, started in the session directory', () {
      expect(
        remoteShellCommand(commandShell: CommandShell.posix, shell: '/bin/zsh', cwd: "/home/omp/it's here"),
        "cd '/home/omp/it'\\''s here'; exec '/bin/zsh' -l",
      );
      expect(remoteShellCommand(commandShell: CommandShell.posix, shell: null, cwd: null), "exec '/bin/sh' -l");
    });

    test('Windows: cmd.exe or the PowerShell default shell, in the session directory', () {
      expect(
        remoteShellCommand(commandShell: CommandShell.cmd, shell: null, cwd: r'C:\Users\omp\proj'),
        r'cd /d "C:\Users\omp\proj" & cmd.exe',
      );
      expect(
        remoteShellCommand(
          commandShell: CommandShell.powershell,
          shell: r'C:\Program Files\PowerShell\7\pwsh.exe',
          cwd: r"C:\Users\o'brien",
        ),
        r"Set-Location -LiteralPath 'C:\Users\o''brien'; & 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo",
      );
    });
  });

  group('local shell', () {
    test("the user's login shell, with a UTF-8 locale when the app has none", () {
      final shell = localShell(windows: false, environment: const {'SHELL': '/bin/zsh', 'PATH': '/usr/bin'});
      expect(shell.executable, '/bin/zsh');
      expect(shell.arguments, ['-l']);
      expect(shell.environment, {'TERM': 'xterm-256color', 'COLORTERM': 'truecolor', 'LANG': 'en_US.UTF-8'});
      final withLocale = localShell(windows: false, environment: const {'SHELL': 'zsh', 'LC_ALL': 'de_DE.UTF-8'});
      expect(withLocale.executable, '/bin/sh');
      expect(withLocale.environment.containsKey('LANG'), isFalse);
    });

    test('an isolated development home: its variables, its omp first on PATH, and no login profile', () {
      final shell = localShell(
        windows: false,
        environment: const {'SHELL': '/bin/zsh', 'PATH': '/opt/homebrew/bin:/usr/bin', 'LANG': 'C.UTF-8'},
        isolation: const {'HOME': '/tmp/dev', 'PATH': '/usr/bin:/bin', 'OMP_PROFILE': ''},
      );
      expect(shell.arguments, isEmpty);
      expect(shell.environment['HOME'], '/tmp/dev');
      expect(shell.environment['PATH'], '/tmp/dev/.local/bin:/usr/bin:/bin');
      expect(shell.environment['OMP_PROFILE'], '');
    });

    test('Windows runs PowerShell', () {
      final shell = localShell(windows: true, environment: const {});
      expect(shell.executable, 'powershell.exe');
      expect(shell.arguments, ['-NoLogo']);
    });
  });
}
