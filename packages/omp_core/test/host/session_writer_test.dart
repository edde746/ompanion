import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

/// The probe the app's guard rests on, against this computer (POSIX shell; `/proc` on Linux, `lsof` on macOS), and
/// the rule that says whether the other process is in a turn.
void main() {
  group('turnInFlight', () {
    Map<String, Object?> message(String role, {String? stopReason}) => {
      'type': 'message',
      'message': {'role': role, 'stopReason': ?stopReason},
    };
    const compaction = {'type': 'compaction', 'summary': 'earlier turns'};

    test('a turn is open from the prompt until an assistant message ends it', () {
      expect(turnInFlight([message('user')]), isTrue, reason: 'the model has not answered yet');
      expect(turnInFlight([message('user'), message('assistant', stopReason: 'toolUse')]), isTrue);
      expect(
        turnInFlight([message('user'), message('assistant', stopReason: 'toolUse'), message('toolResult')]),
        isTrue,
        reason: 'the next assistant message is streaming; omp appends it when it ends',
      );
      for (final reason in ['stop', 'length', 'error', 'aborted']) {
        expect(turnInFlight([message('user'), message('assistant', stopReason: reason)]), isFalse, reason: reason);
      }
    });

    test('entries that are not messages leave the answer to the last message', () {
      expect(turnInFlight([message('user'), message('assistant', stopReason: 'stop'), compaction]), isFalse);
      expect(turnInFlight([message('user'), compaction]), isTrue);
      expect(turnInFlight([compaction]), isFalse);
      expect(turnInFlight([message('assistant', stopReason: 'stop'), message('bashExecution')]), isFalse);
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

    test("the app's own run is not a holder", () {
      expect(parseSessionWriter('holder 41\nholder 42\n', runPid: 41)?.pids, [42]);
      expect(parseSessionWriter('holder 41\n', runPid: 41), isNull);
    });
  });

  group('probeSessionWriter', () {
    late Directory dir;
    late HostLink link;
    late HostProbe probe;
    // Every character the probe script's quoting has to survive.
    late String path;

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
      final sessions = Directory("${dir.path}/it's \$HOME `id` \\n dir")..createSync();
      path = '${sessions.path}/session.jsonl';
      await File(path).writeAsString('{"type":"session"}\n');
    });

    tearDown(() async {
      await link.close();
      await dir.delete(recursive: true);
    });

    test('a process holding the file open for writing is found', () async {
      // A descriptor held for writing, kept open by this child until it is killed.
      final holder = await Process.start('/bin/sh', ['-c', 'exec 9>>"\$0"; sleep 60', path]);
      addTearDown(() => holder.kill());
      await Future<void>.delayed(const Duration(seconds: 1));

      final writer = await probeSessionWriter(link, probe, path);
      expect(writer?.pids, contains(holder.pid));
      expect(writer?.terminal, isNull);
    });

    test('a reader is not a writer', () async {
      final reader = await Process.start('/bin/sh', ['-c', 'exec 9<"\$0"; sleep 60', path]);
      addTearDown(() => reader.kill());
      await Future<void>.delayed(const Duration(seconds: 1));

      expect(await probeSessionWriter(link, probe, path), isNull);
    });

    test('a terminal breadcrumb of the file with a live omp on that tty is found', () async {
      final fake = await _fakeOmpOnPty(dir);
      if (fake == null) {
        markTestSkipped('`script` gives no pty here');
        return;
      }
      addTearDown(fake.kill);
      final breadcrumbs = Directory('${probe.agentDir}/terminal-sessions')..createSync(recursive: true);
      File('${breadcrumbs.path}/${fake.breadcrumbId}').writeAsStringSync('${dir.path}\n$path\n');

      final writer = await probeSessionWriter(link, probe, path);
      expect(writer?.terminal, fake.breadcrumbId);
      expect(writer?.pids, isEmpty, reason: 'this fake omp never wrote to the file');
    });

    test('a breadcrumb whose terminal runs nothing is stale, not a writer', () async {
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
