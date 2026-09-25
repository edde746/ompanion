import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/screens/dock/agents/agent_transcript.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

/// omp that does not know the subagent, so the transcript is read from its session file.
final class _Omp implements LineChannel {
  final _lines = StreamController<String>();

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    final type = json['type'];
    scheduleMicrotask(
      () => _lines.add(
        jsonEncode({
          'type': 'response',
          'id': json['id'],
          'command': type,
          'success': type == 'negotiate_protocol',
          if (type == 'negotiate_protocol') 'data': {'protocolVersion': 2} else 'error': 'unknown subagent',
        }),
      ),
    );
  }

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  @override
  late final RpcClient rpc = RpcClient(_Omp(), deviceId: 'test');

  @override
  CompanionClient get companion => throw UnimplementedError();

  @override
  CompanionHello? get companionHello => null;

  @override
  SessionView get view => SessionView();

  @override
  Stream<SessionView> get views => const Stream.empty();

  @override
  String get runId => 'run';

  @override
  String? get sessionPath => null;

  @override
  String get cwd => '/tmp';

  @override
  LinkState get linkState => const LinkLive();

  @override
  Stream<LinkState> get linkStates => const Stream.empty();

  @override
  void dismissRequest(String id) {}

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() async {}
}

/// File access to a machine without the session file, or whose every read fails, as on a link that dropped;
/// records whether it was closed.
final class _Files implements HostFiles {
  _Files({this.failing = false});

  final bool failing;
  var closed = false;

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) async =>
      failing ? throw HostLinkException('connection lost') : null;

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) => throw HostLinkException('connection lost');

  @override
  Future<List<HostDirEntry>> list(String path) => throw UnimplementedError();

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) => throw UnimplementedError();

  @override
  Future<void> mkdir(String path, {int? mode}) => throw UnimplementedError();

  @override
  Future<void> remove(String path) => throw UnimplementedError();

  @override
  Future<void> removeDir(String path) => throw UnimplementedError();

  @override
  Future<void> rename(String from, String to) => throw UnimplementedError();

  @override
  Future<String> home() => throw UnimplementedError();

  @override
  Future<void> close() async => closed = true;
}

void main() {
  test('file access is closed when a read fails, and when it opens after the transcript closed', () async {
    final session = _Session();
    await session.rpc.attach();

    final opened = <_Files>[];
    final failing = AgentTranscript(
      session: session,
      agentId: 'Echo',
      sessionFile: '/tmp/echo.jsonl',
      openFiles: () async {
        final files = _Files(failing: true);
        opened.add(files);
        return files;
      },
    );
    await pumpEventQueue();
    expect(failing.error, isA<HostLinkException>());
    expect(opened.single.closed, isTrue);
    failing.dispose();

    final opening = Completer<HostFiles>();
    final closedEarly = AgentTranscript(
      session: session,
      agentId: 'Echo',
      sessionFile: '/tmp/echo.jsonl',
      openFiles: () => opening.future,
    );
    await pumpEventQueue();
    closedEarly.dispose();
    final late = _Files();
    opening.complete(late);
    await pumpEventQueue();
    expect(late.closed, isTrue);
  });
}
