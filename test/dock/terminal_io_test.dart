import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/terminal/shell_launch.dart';
import 'package:omp_app/terminal/terminal_deck.dart';
import 'package:omp_app/terminal/terminal_session.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:xterm3/xterm.dart';

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

  group('remote shell launch', () {
    test('POSIX: the login shell parses a fixed command; the directory follows on stdin', () {
      // fish reads \' inside single quotes as an escaped quote, so no sh quoting of the name is safe there.
      const cwd = r"/home/omp/it\'s;touch pwned;#";
      final launch = remoteShellLaunch(commandShell: CommandShell.posix, shell: '/usr/bin/fish', cwd: cwd);
      expect(launch.command, posixTerminalCommand);
      expect(launch.startLine, '$cwd\n');
      expect(remoteShellLaunch(commandShell: CommandShell.posix, shell: null, cwd: null).startLine, '\n');
      // The rest of the name would reach the login shell as typed input.
      expect(remoteShellLaunch(commandShell: CommandShell.posix, shell: null, cwd: '/tmp/a\nrm -rf ~').startLine, '\n');
    });

    test('Windows: cmd.exe or the PowerShell default shell, in the session directory', () {
      final cmd = remoteShellLaunch(commandShell: CommandShell.cmd, shell: null, cwd: r'C:\Users\omp\proj');
      expect(cmd, (command: r'cd /d "C:\Users\omp\proj" & cmd.exe', startLine: null));
      final powershell = remoteShellLaunch(
        commandShell: CommandShell.powershell,
        shell: r'C:\Program Files\PowerShell\7\pwsh.exe',
        cwd: r"C:\Users\o'brien",
      );
      expect(
        powershell,
        (
          command: r"Set-Location -LiteralPath 'C:\Users\o''brien'; & 'C:\Program Files\PowerShell\7\pwsh.exe' -NoLogo",
          startLine: null,
        ),
      );
    });

    test('the ready line is taken out of the output, even split across chunks', () {
      final filter = TerminalReadyFilter();
      expect(filter.add(ascii.encode('motd\r\nOMPAPP_TERMINAL')), isEmpty);
      expect(filter.add(ascii.encode('_READY')), isEmpty);
      expect(filter.ready, isFalse);
      expect(ascii.decode(filter.add(ascii.encode('\n\$ '))), 'motd\r\n\$ ');
      expect(filter.ready, isTrue);
      expect(ascii.decode(filter.add(ascii.encode('OMPAPP_TERMINAL_READY\n'))), 'OMPAPP_TERMINAL_READY\n');

      // A shell tracing the command prints the marker mid-line first; only the line itself counts.
      final traced = TerminalReadyFilter();
      expect(traced.add(ascii.encode("+ echo OMPAPP_TERMINAL_READY; IFS= read\r\nOMPAPP_TERMINAL_READY\r")), isEmpty);
      expect(ascii.decode(traced.add(ascii.encode('\nok'))), '+ echo OMPAPP_TERMINAL_READY; IFS= read\r\nok');

      final failed = TerminalReadyFilter();
      expect(failed.add(ascii.encode('sh: not found\r\n')), isEmpty);
      expect(ascii.decode(failed.close()), 'sh: not found\r\n');
    });

    test('the PTY takes sizes at once; the directory waits for the ready line, and keystrokes for the directory', () async {
      final link = _PtyLink();
      const launch = (command: posixTerminalCommand, startLine: '/srv/app\n');
      final started = SshTerminalBackend.start(link, launch, columns: 80, rows: 24);
      final process = await link.started.future;
      final backend = await started;
      expect(link.command, posixTerminalCommand);
      final shown = StringBuffer();
      final done = backend.output.listen((bytes) => shown.write(utf8.decode(bytes))).asFuture<void>();

      // Before the login shell exists, the view's size already reaches the PTY; typing waits.
      backend.resize(100, 40, 0, 0);
      backend.write(encodeTerminalInput('ls\r'));
      expect(process.sizes, [(100, 40)]);
      process.emit('Last login: today\r\n');
      await pumpEventQueue();
      expect(process.written, isEmpty);

      process.emit('OMPAPP_TERMINAL_READY\n');
      await pumpEventQueue();
      expect(process.written, ['/srv/app\n', 'ls\r']);
      backend.write(encodeTerminalInput('pwd\r'));
      expect(process.written, ['/srv/app\n', 'ls\r', 'pwd\r']);

      process.emit('~/srv/app \$ ');
      await process.end();
      await done;
      expect(shown.toString(), 'Last login: today\r\n~/srv/app \$ ');
    });

    test('a shell that ends before the ready line shows why', () async {
      final link = _PtyLink();
      final started = SshTerminalBackend.start(link, (command: posixTerminalCommand, startLine: '\n'), columns: 80, rows: 24);
      final process = await link.started.future;
      final backend = await started;
      backend.write(encodeTerminalInput('ls\r'));
      process.emit('This account is currently not available.\r\n');
      await process.end();
      expect(utf8.decode((await backend.output.toList()).expand((bytes) => bytes).toList()), 'This account is currently not available.\r\n');
      expect(process.written, isEmpty);
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

    test("without SHELL the account's shell from the user database, else /bin/sh", () {
      final account = localShell(windows: false, environment: const {'USER': 'me'}, accountShell: '/opt/homebrew/bin/fish');
      expect(account.executable, '/opt/homebrew/bin/fish');
      expect(account.arguments, ['-l']);
      // The environment's own SHELL wins over the database.
      expect(localShell(windows: false, environment: const {'SHELL': '/bin/zsh'}, accountShell: '/bin/bash').executable, '/bin/zsh');
      expect(localShell(windows: false, environment: const {}, accountShell: null).executable, '/bin/sh');
      // A development home keeps the account's shell but not its login profile.
      final isolated = localShell(
        windows: false,
        environment: const {},
        accountShell: '/bin/zsh',
        isolation: const {'HOME': '/tmp/dev', 'PATH': '/usr/bin:/bin'},
      );
      expect(isolated.executable, '/bin/zsh');
      expect(isolated.arguments, isEmpty);
    });

    test('the account shell from dscl and passwd output', () {
      expect(parseDsclUserShell('UserShell: /bin/zsh\n'), '/bin/zsh');
      expect(parseDsclUserShell('No such key: UserShell\n'), isNull);
      expect(parsePasswdShell('me:x:501:20:Me:/home/me:/usr/bin/fish\n'), '/usr/bin/fish');
      expect(parsePasswdShell('me:x:501:20:Me:/home/me:\n'), isNull);
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

  group('tabs', () {
    testWidgets('closing a tab to the left of the selected one keeps that one selected', (tester) async {
      TerminalSession tab(String title) =>
          TerminalSession(title: title, open: (columns, rows) => Completer<TerminalBackend>().future);
      final (a, b, c) = (tab('a'), tab('b'), tab('c'));
      final deck = TerminalDeck()
        ..add(a)
        ..add(b)
        ..add(c)
        ..select(1);
      deck.close(a);
      expect(deck.current, same(b));
      deck.close(c);
      expect(deck.current, same(b));
      deck.dispose();
    });
  });

  group('PTY size', () {
    testWidgets('opens at the laid-out grid and follows the view, also while the PTY opens', (tester) async {
      final opening = Completer<TerminalBackend>();
      final opened = <(int, int)>[];
      final backend = _Backend();
      final session = TerminalSession(
        title: 'sh',
        open: (columns, rows) {
          opened.add((columns, rows));
          return opening.future;
        },
      );
      var size = const Size(600, 400);
      late StateSetter setSize;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              setSize = setState;
              return Align(
                alignment: Alignment.topLeft,
                child: SizedBox.fromSize(size: size, child: TerminalView(session.terminal)),
              );
            },
          ),
        ),
      );
      await tester.pump();
      (int, int) grid() => (session.terminal.viewWidth, session.terminal.viewHeight);
      expect(opened, [grid()]);
      expect(grid(), isNot((80, 24)));

      // The dock widens while the PTY opens: the PTY gets the new grid before any output is drawn.
      setSize(() => size = const Size(800, 500));
      await tester.pump();
      expect(backend.sizes, isEmpty);
      opening.complete(backend);
      await tester.pump();
      expect(backend.sizes, [grid()]);
      expect(session.phase, isA<TerminalRunning>());

      setSize(() => size = const Size(500, 300));
      await tester.pump();
      expect(backend.sizes.last, grid());
      expect(backend.pixels.last.$1, greaterThan(grid().$1), reason: 'the grid in pixels, not one cell');

      await tester.pumpWidget(const SizedBox());
      session.dispose();
    });
  });

  group('exited shell', () {
    testWidgets('resizing and pasting no longer reach it, and the grid still follows the view', (tester) async {
      final backend = _Backend();
      final session = TerminalSession(title: 'sh', open: (columns, rows) async => backend);
      session.terminal.resize(90, 30);
      await tester.pump();
      expect(session.phase, isA<TerminalRunning>());
      session.terminal.resize(95, 30);
      expect(backend.sizes, [(95, 30)]);

      backend.exit(0);
      await tester.pump();
      expect(session.phase, isA<TerminalExited>());
      session.terminal.resize(100, 40);
      session.terminal.paste('ls');
      expect((session.terminal.viewWidth, session.terminal.viewHeight), (100, 40));
      expect(backend.written, isEmpty);

      session.dispose();
      expect(backend.closed, isTrue);
    });

    testWidgets('a close that fails while the tab goes away is no uncaught error', (tester) async {
      // A live local shell when the app shuts down: the PTY may refuse the hang-up signal or the kill.
      final backend = _Backend()..closeError = StateError('sending POSIX signal failed');
      final session = TerminalSession(title: 'sh', open: (columns, rows) async => backend);
      session.terminal.resize(90, 30);
      await tester.pump();
      expect(session.phase, isA<TerminalRunning>());

      session.dispose();
      await tester.pump();
      expect(backend.closed, isTrue);
    });
  });
}

/// A link whose one PTY process is driven by the test.
final class _PtyLink implements HostLink {
  final started = Completer<_PtyProcess>();
  String? command;

  @override
  String get label => 'test';

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) async {
    this.command = command;
    final process = _PtyProcess();
    started.complete(process);
    return process;
  }

  @override
  Future<HostFiles> files() => throw UnimplementedError();

  @override
  Future<HostSocket> connect(String host, int port) => throw UnimplementedError();

  @override
  Future<void> get done => Completer<void>().future;

  @override
  Future<void> close() async {}
}

final class _PtyProcess implements HostProcess {
  final _stdout = StreamController<Uint8List>();
  final _exit = Completer<HostExit>();
  final written = <String>[];
  final sizes = <(int, int)>[];

  void emit(String text) => _stdout.add(utf8.encode(text));

  Future<void> end() async {
    await _stdout.close();
    _exit.complete(const HostExit(code: 0));
  }

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(List<int> bytes) => written.add(utf8.decode(bytes));

  @override
  Future<void> closeStdin() async {}

  @override
  Future<HostExit> get exit => _exit.future;

  @override
  void resize(int columns, int rows) => sizes.add((columns, rows));

  @override
  void kill() {}

  @override
  Future<void> close() async {}
}

/// A shell that exits when told. Afterwards writes and resizes throw, as they do on a PTY whose shell exited.
final class _Backend implements TerminalBackend {
  final _output = StreamController<Uint8List>();
  final _exit = Completer<int?>();
  final written = <String>[];
  final sizes = <(int, int)>[];
  final pixels = <(int, int)>[];
  var closed = false;
  Object? closeError;

  void exit(int code) {
    _exit.complete(code);
    unawaited(_output.close());
  }

  @override
  Stream<Uint8List> get output => _output.stream;

  @override
  void write(Uint8List bytes) {
    if (_exit.isCompleted) throw StateError('PTY closed');
    written.add(utf8.decode(bytes));
  }

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {
    if (_exit.isCompleted) throw StateError('PTY closed');
    sizes.add((columns, rows));
    pixels.add((pixelWidth, pixelHeight));
  }

  @override
  Future<int?> get exitCode => _exit.future;

  @override
  Future<void> close() async {
    closed = true;
    if (closeError case final error?) throw error;
  }
}
