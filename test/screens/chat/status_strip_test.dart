import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/chat/status_strip.dart';
import 'package:omp_core/companion.dart' show CompanionClient, CompanionHello;
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

final class _Session implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  _Session(this._view);

  SessionView _view;
  final _views = StreamController<SessionView>.broadcast();

  void emit(SessionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  LinkState get linkState => const LinkLive();

  @override
  Stream<LinkState> get linkStates => const Stream.empty();

  @override
  RpcClient get rpc => throw UnimplementedError();

  @override
  CompanionClient get companion => throw UnimplementedError();

  @override
  CompanionHello? get companionHello => null;

  @override
  String get runId => 'run';

  @override
  String? get sessionPath => '/tmp/s.jsonl';

  @override
  String get cwd => '/tmp';

  @override
  void dismissRequest(String id) {}

  @override
  void setPendingPrompt(PendingPrompt? prompt) {}

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async {}

  @override
  Future<void> stop() async {}
}

Future<void> _pump(WidgetTester tester, _Session session) async {
  await tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              StatusStrip(session: session),
              const Expanded(child: SizedBox()),
              CommandOutputs(session: session),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a command output that arrives after the chat opened shows', (tester) async {
    final session = _Session(SessionView());
    await _pump(tester, session);

    session.emit(
      reduce(session.view, const {'type': 'command_output', 'text': 'Compaction failed: nothing to compact'}),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Compaction failed: nothing to compact'), findsOneWidget);
  });

  testWidgets('Stopped shows after a stop and then leaves the strip', (tester) async {
    final session = _Session(SessionView(run: const RunState(running: true)));
    await _pump(tester, session);
    final strip = find.byType(StatusStrip);
    expect(tester.getSize(strip).height, 0);

    session.emit(session.view.copyWith(run: const RunState(outcome: RunAborted())));
    await tester.pumpAndSettle();
    expect(find.text(t.chat.aborted), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    expect(find.text(t.chat.aborted), findsNothing);
    expect(tester.getSize(strip).height, 0);

    // A strip built again, as another layout does, does not show the old stop anew.
    await tester.pumpWidget(const SizedBox());
    await _pump(tester, session);
    await tester.pumpAndSettle();
    expect(find.text(t.chat.aborted), findsNothing);

    // The next stop shows it again.
    session.emit(session.view.copyWith(run: const RunState(running: true)));
    await tester.pumpAndSettle();
    session.emit(session.view.copyWith(run: const RunState(outcome: RunAborted())));
    await tester.pumpAndSettle();
    expect(find.text(t.chat.aborted), findsOneWidget);
    await tester.pump(const Duration(seconds: 10));
  });
}
