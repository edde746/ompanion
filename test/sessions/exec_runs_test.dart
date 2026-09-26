import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/sessions/exec_runs.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

/// Accepts every command; companion calls get their reply when the test sends it.
final class _Omp implements LineChannel {
  final _lines = StreamController<String>();
  String? lastCallId;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    if (json case {'type': 'prompt', 'message': final String message} when message.startsWith('/ompx ')) {
      lastCallId = (jsonDecode(message.substring('/ompx '.length)) as Map<String, Object?>)['callId']! as String;
    }
    final id = json['id'];
    if (id == null) return;
    final data = json['type'] == 'negotiate_protocol' ? {'protocolVersion': 2} : null;
    scheduleMicrotask(
      () => _lines.add(
        jsonEncode({'type': 'response', 'id': id, 'command': json['type'], 'success': true, 'data': ?data}),
      ),
    );
  }

  void reply(String output) => _lines.add(
    jsonEncode({
      'type': 'ompx',
      'kind': 'reply',
      'callId': lastCallId,
      'ok': true,
      'result': {'output': output, 'exitCode': 0, 'cancelled': false, 'truncated': false},
    }),
  );

  @override
  Future<void> close() async => _lines.close();
}

final class _Session implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  _Session(this._view);

  SessionView _view;
  final _views = StreamController<SessionView>.broadcast(sync: true);
  final omp = _Omp();
  @override
  late final RpcClient rpc = RpcClient(omp, deviceId: 'test');
  @override
  late final CompanionClient companion = CompanionClient(rpc);

  void emit(SessionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  CompanionHello? get companionHello => null;

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

ExecutionItem _row(int timestamp, {String command = 'echo hi', ExecutionKind kind = ExecutionKind.bash}) =>
    ExecutionItem(kind: kind, timestamp: timestamp, command: command, output: 'hi\n', exitCode: 0);

Future<void> _settle() async {
  for (var i = 0; i < 10; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _Session session;
  late ExecRuns runs;

  setUp(() async {
    session = _Session(SessionView());
    await session.rpc.attach();
    runs = ExecRuns();
  });

  tearDown(() => runs.dispose());

  test('an idle session: the row lands before the reply, and the card leaves with the reply', () async {
    runs.start(session, ExecutionKind.bash, 'echo hi', excludeFromContext: false);
    await _settle();
    session.emit(SessionView(transcript: [_row(1000)]));
    expect(runs.runs.single.running, isTrue, reason: 'the card shows while the run streams');
    session.omp.reply('hi\n');
    await _settle();
    expect(runs.runs, isEmpty);
  });

  test('while a turn streams omp holds the row: the finished card stays until the row lands', () async {
    runs.start(session, ExecutionKind.bash, 'echo hi', excludeFromContext: false);
    await _settle();
    session.omp.reply('hi\n');
    await _settle();
    final run = runs.runs.single;
    expect(run.running, isFalse);
    expect(run.output, 'hi\n');
    session.emit(
      SessionView(
        transcript: [
          UserItem(timestamp: 1, content: const [TextBlock('go on')]),
        ],
      ),
    );
    expect(runs.runs, [run]);
    session.emit(
      SessionView(
        transcript: [
          _row(1000),
          UserItem(timestamp: 2, content: const [TextBlock('go on')]),
        ],
      ),
    );
    expect(runs.runs, isEmpty);
  });

  test('an earlier run of the same command, or another kind, is not taken for this run', () async {
    session.emit(SessionView(transcript: [_row(500)]));
    runs.start(session, ExecutionKind.bash, 'echo hi', excludeFromContext: false);
    await _settle();
    session.omp.reply('hi\n');
    await _settle();
    expect(runs.runs, hasLength(1));
    session.emit(
      SessionView(
        transcript: [
          _row(500),
          _row(900, kind: ExecutionKind.python),
        ],
      ),
    );
    expect(runs.runs, hasLength(1));
    session.emit(
      SessionView(
        transcript: [
          _row(500),
          _row(900, kind: ExecutionKind.python),
          _row(1000),
        ],
      ),
    );
    expect(runs.runs, isEmpty);
  });
}
