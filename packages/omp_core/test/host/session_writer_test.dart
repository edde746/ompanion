import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

/// The two rules the app's guard rests on, and the probe that feeds them: who owns a session file, and whether a
/// writer the machine reported is writing right now. The probe runs against this computer (POSIX shell, `lsof` or
/// `/proc`), so the run is skipped where neither exists.
void main() {
  group('sessionOwnership', () {
    test('an app run owns the file, whatever else holds it', () {
      expect(sessionOwnership(appRun: true, writer: const ExternalWriter(pids: [1])), SessionOwnership.appRun);
    });

    test('a writer the app did not start owns it', () {
      expect(sessionOwnership(appRun: false, writer: const ExternalWriter(pids: [1])), SessionOwnership.foreign);
      expect(
        sessionOwnership(
          appRun: false,
          writer: const ExternalWriter(pids: [], terminal: 'ttys004'),
        ),
        SessionOwnership.foreign,
        reason: 'omp closes its append descriptor at the end of a turn; the breadcrumb still names the writer',
      );
    });

    test('nobody holds it', () {
      expect(sessionOwnership(appRun: false, writer: null), SessionOwnership.free);
    });
  });

  group('polledWriter', () {
    test('a write means a turn is running, and restarts the quiet clock', () {
      final appended = polledWriter(
        probed: const ExternalWriter(pids: [], terminal: 'ttys004', idleFor: Duration(seconds: 40)),
        changed: true,
        quietFor: const Duration(seconds: 40),
      );
      expect(appended?.busy, isTrue, reason: 'the file grew between polls: a turn is running');
      expect(appended?.idleFor, Duration.zero);
    });

    test('a held descriptor alone is not a running turn', () {
      // omp keeps the session file open for the life of the process; an idle omp at its prompt holds it too.
      final held = polledWriter(
        probed: const ExternalWriter(pids: [7], terminal: 'ttys004'),
        changed: false,
        quietFor: const Duration(seconds: 40),
      );
      expect(held?.pids, [7], reason: 'the writer still owns the session, so the app still must not launch');
      expect(held?.busy, isFalse);
      expect(held?.idleFor, const Duration(seconds: 40));

      final writing = polledWriter(
        probed: const ExternalWriter(pids: [7], terminal: 'ttys004'),
        changed: false,
        quietFor: const Duration(seconds: 3),
      );
      expect(writing?.busy, isTrue, reason: 'a write within the window is a turn still running');
    });

    test('nobody there stays nobody there', () {
      expect(polledWriter(probed: null, changed: true, quietFor: Duration(seconds: 30)), isNull);
    });
  });

  group('parseSessionWriter', () {
    test('reads holders and a terminal', () {
      final writer = parseSessionWriter('holder 41\nholder 42\nterminal ttys004 41\n');
      expect(writer?.pids, [41, 42]);
      expect(writer?.terminal, 'ttys004');
    });

    test('no holder and no terminal is no writer', () {
      expect(parseSessionWriter(''), isNull);
      expect(parseSessionWriter('holder x\nterminal ttys004\n'), isNull, reason: 'an unparsable pid is not a holder');
    });

    test('a terminal without a live pid is dropped', () {
      final writer = parseSessionWriter('terminal ttys004\nholder 9\n');
      expect(writer?.terminal, isNull);
      expect(writer?.pids, [9]);
    });
  });

  group('probeSessionWriter', () {
    late Directory dir;
    late HostLink link;
    late HostProbe probe;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('ompanion-writer-');
      link = LocalLink();
      probe = HostProbe(
        commandShell: CommandShell.posix,
        os: Platform.isMacOS ? HostOs.macos : HostOs.linux,
        kernel: Platform.isMacOS ? 'Darwin' : 'Linux',
        arch: 'arm64',
        home: dir.path,
        agentDir: '${dir.path}/.omp/agent',
      );
    });

    tearDown(() async {
      await link.close();
      await dir.delete(recursive: true);
    });

    test('a process holding the file open for writing is found', () async {
      final path = '${dir.path}/session.jsonl';
      await File(path).writeAsString('{"type":"session"}\n');
      // A descriptor held for writing, kept open by this child until it is killed.
      final holder = await Process.start('/bin/sh', ['-c', 'exec 9>>"\$0"; sleep 60', path]);
      addTearDown(() => holder.kill());
      await Future<void>.delayed(const Duration(seconds: 1));

      final writer = await probeSessionWriter(link, probe, path);
      expect(writer?.pids, contains(holder.pid));
      expect(writer?.terminal, isNull);
    });

    test('a reader is not a writer', () async {
      final path = '${dir.path}/session.jsonl';
      await File(path).writeAsString('{"type":"session"}\n');
      final reader = await Process.start('/bin/sh', ['-c', 'exec 9<"\$0"; sleep 60', path]);
      addTearDown(() => reader.kill());
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(await probeSessionWriter(link, probe, path), isNull);
    }, skip: !Platform.isMacOS && !Directory('/usr/bin/lsof').existsSync() && !Directory('/proc').existsSync());

    test('a terminal breadcrumb of the file with a live omp on that tty is found', () async {
      final fake = await _fakeOmpOnPty(dir);
      if (fake == null) return;
      addTearDown(fake.kill);
      final path = '${dir.path}/session.jsonl';
      await File(path).writeAsString('{"type":"session"}\n');
      final breadcrumbs = Directory('${probe.agentDir}/terminal-sessions')..createSync(recursive: true);
      File('${breadcrumbs.path}/${fake.breadcrumbId}').writeAsStringSync('${dir.path}\n$path\n');

      final writer = await probeSessionWriter(link, probe, path);
      expect(writer?.terminal, fake.breadcrumbId);
      expect(writer?.pids, isEmpty, reason: 'this fake omp never wrote to the file');
    });

    test('a breadcrumb whose terminal runs nothing is stale, not a writer', () async {
      final path = '${dir.path}/session.jsonl';
      await File(path).writeAsString('{"type":"session"}\n');
      final breadcrumbs = Directory('${probe.agentDir}/terminal-sessions')..createSync(recursive: true);
      // omp never removes a breadcrumb, so one of a closed terminal must not lock the app out of its own session.
      File('${breadcrumbs.path}/ttys999').writeAsStringSync('${dir.path}\n$path\n');
      File('${breadcrumbs.path}/tmux-%7').writeAsStringSync('${dir.path}\n$path\n');

      expect(await probeSessionWriter(link, probe, path), isNull);
    });
  });
}

typedef _FakeOmp = ({int pid, String breadcrumbId, void Function() kill});

/// A process whose command is an `omp` on a pty, so the probe's tty mapping has something to find: `script` gives
/// the child a terminal, and the child is a copy of this script named `omp`. Null where `script` cannot start one.
Future<_FakeOmp?> _fakeOmpOnPty(Directory dir) async {
  final bin = Directory('${dir.path}/bin')..createSync(recursive: true);
  final omp = File('${bin.path}/omp')..writeAsStringSync('#!/bin/sh\nsleep 120\n');
  Process.runSync('chmod', ['+x', omp.path]);
  final process = await Process.start('script', [
    if (!Platform.isMacOS) ...['-q', '-c', omp.path, '/dev/null'],
    if (Platform.isMacOS) ...['-q', '/dev/null', omp.path],
  ]);
  final tty = await _ttyOf(omp.path);
  if (tty == null) {
    process.kill();
    return null;
  }
  return (
    pid: process.pid,
    breadcrumbId: tty.startsWith('pts/') ? tty.replaceFirst('pts/', 'pts-') : tty,
    kill: () => process.kill(),
  );
}

/// The tty of the process whose command line holds [command], as `ps` prints it (`ttys004`, `pts/3`).
Future<String?> _ttyOf(String command) async {
  for (var attempt = 0; attempt < 40; attempt++) {
    final result = await Process.run('ps', ['-eo', 'pid=,tty=,command=']);
    for (final line in const LineSplitter().convert(result.stdout as String)) {
      if (line.contains(command) && !line.contains('sed') && !line.contains('ps -eo')) {
        final fields = line.trim().split(RegExp(r'\s+'));
        if (fields.length > 2 && fields[1] != '??' && fields[1] != '?') return fields[1];
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return null;
}
