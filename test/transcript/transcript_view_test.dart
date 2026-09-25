import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/i18n/strings.g.dart';
import 'package:omp_app/screens/chat/transcript/message_rows.dart';
import 'package:omp_app/screens/chat/transcript/transcript_view.dart';
import 'package:omp_core/store.dart';

import 'fixtures.dart';

final _actions = TranscriptActions(
  onBranchFrom: (_) {},
  onCopy: (_) {},
  onOpenFile: (path, {line}) {},
  onOpenSubagent: (_) {},
);

Widget _harness(SessionView view, {bool alignTop = false}) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(body: TranscriptView(view: view, actions: _actions, alignTop: alignTop)),
  ),
);

ScrollPosition _position(WidgetTester tester) => tester
    .state<ScrollableState>(
      find.byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down).first,
    )
    .position;

UserItem _user(int n) => UserItem(timestamp: n, content: [TextBlock('Question $n')]);

AssistantItem _answer(int n, String text, {bool streaming = false}) => AssistantItem(
  timestamp: n,
  content: [TextBlock(text)],
  provider: 'fake',
  model: 'fake-1',
  stopReason: StopReason.stop,
  streaming: streaming,
);

String _paragraphs(int n) => List.generate(n, (i) => 'Line $i of a reply that takes some room.').join('\n\n');

/// Question/answer pairs [from] until [to].
List<TranscriptItem> _turns(int from, int to) => [
  for (var n = from; n < to; n++) ...[_user(n * 2), _answer(n * 2 + 1, _paragraphs(3))],
];

void main() {
  setUp(() {
    final binding = TestWidgetsFlutterBinding.ensureInitialized();
    binding.platformDispatcher.views.first.physicalSize = const Size(1000, 800);
    binding.platformDispatcher.views.first.devicePixelRatio = 1;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  group('recorded sessions', () {
    for (final name in fixtureNames()) {
      testWidgets('$name renders every step, then with every card open', (tester) async {
        final replay = replayFixture(name);
        for (final view in replay.views) {
          await tester.pumpWidget(_harness(view));
        }
        final last = replay.views.last;
        if (last.transcript.isNotEmpty) expect(find.byType(TranscriptRowView), findsWidgets);
        // Open every collapsed card and summary so every body renders once.
        for (var round = 0; round < 3; round++) {
          final closed = find.byIcon(Icons.expand_more);
          if (closed.evaluate().isEmpty) break;
          for (final element in closed.evaluate().toList()) {
            await tester.tap(find.byWidget(element.widget).first, warnIfMissed: false);
          }
          await tester.pump();
        }
        final reference = replay.reference;
        if (reference != null) await tester.pumpWidget(_harness(reference));
        expect(tester.takeException(), isNull);
      });
    }
  });

  testWidgets('follows a streaming reply at the bottom, and stays put once the reader scrolls up', (tester) async {
    final history = _turns(0, 20);
    await tester.pumpWidget(_harness(SessionView(transcript: history, historyLength: history.length)));
    final position = _position(tester);
    expect(position.pixels, position.maxScrollExtent);

    // The user sends a prompt and the reply streams in.
    final prompt = _user(100);
    var transcript = [...history, prompt];
    await tester.pumpWidget(_harness(SessionView(transcript: transcript, historyLength: history.length)));
    await tester.pumpAndSettle();
    for (var i = 1; i <= 12; i++) {
      transcript = [...history, prompt, _answer(101, _paragraphs(i), streaming: true)];
      await tester.pumpWidget(_harness(SessionView(transcript: transcript, historyLength: history.length)));
      expect(position.pixels, position.maxScrollExtent, reason: 'update $i stays at the bottom');
    }

    await tester.drag(find.byType(TranscriptView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(position.pixels, lessThan(position.maxScrollExtent - 100));
    final promptRow = find.byKey(ValueKey(prompt.key));
    final pixels = position.pixels;
    final before = tester.getTopLeft(promptRow);
    for (var i = 13; i <= 20; i++) {
      transcript = [...history, prompt, _answer(101, _paragraphs(i), streaming: true)];
      await tester.pumpWidget(_harness(SessionView(transcript: transcript, historyLength: history.length)));
    }
    expect(position.pixels, pixels);
    expect(tester.getTopLeft(promptRow), before, reason: 'growth below the reader moves nothing above it');

    // Jump to latest brings the reader back and it follows again.
    await tester.tap(find.byTooltip(t.transcript.jumpToLatest));
    await tester.pumpAndSettle();
    expect(position.pixels, position.maxScrollExtent);
    transcript = [...history, prompt, _answer(101, _paragraphs(24), streaming: true)];
    await tester.pumpWidget(_harness(SessionView(transcript: transcript, historyLength: history.length)));
    expect(position.pixels, position.maxScrollExtent);
  });

  testWidgets('a reply already streaming when the view opens grows below a reader who scrolled up', (tester) async {
    final history = _turns(0, 20);
    final prompt = _user(100);
    SessionView view(int paragraphs) => SessionView(
      transcript: [...history, prompt, _answer(101, _paragraphs(paragraphs), streaming: true)],
      historyLength: history.length,
    );
    // Switching to a session whose reply is streaming.
    await tester.pumpWidget(_harness(view(2)));
    final position = _position(tester);
    expect(position.pixels, position.maxScrollExtent);
    for (var i = 3; i <= 12; i++) {
      await tester.pumpWidget(_harness(view(i)));
      expect(position.pixels, position.maxScrollExtent, reason: 'update $i stays at the bottom');
    }

    await tester.drag(find.byType(TranscriptView), const Offset(0, 300));
    await tester.pumpAndSettle();
    final promptRow = find.byKey(ValueKey(prompt.key));
    final before = tester.getTopLeft(promptRow);
    for (var i = 13; i <= 20; i++) {
      await tester.pumpWidget(_harness(view(i)));
    }
    expect(tester.getTopLeft(promptRow), before, reason: 'growth below the reader moves nothing above it');
  });

  testWidgets('a reply that starts while the transcript fits grows below a reader who scrolled up', (tester) async {
    final history = _turns(0, 1);
    final prompt = _user(100);
    SessionView view(int paragraphs) => SessionView(
      transcript: [...history, prompt, _answer(101, _paragraphs(paragraphs), streaming: true)],
      historyLength: history.length,
    );
    await tester.pumpWidget(_harness(SessionView(transcript: [...history, prompt], historyLength: history.length)));
    final position = _position(tester);
    // The reply streams past the viewport's height.
    for (var i = 1; i <= 30; i++) {
      await tester.pumpWidget(_harness(view(i)));
      expect(position.pixels, position.maxScrollExtent, reason: 'update $i stays at the bottom');
    }

    await tester.drag(find.byType(TranscriptView), const Offset(0, 300));
    await tester.pumpAndSettle();
    // The reader looks at the middle of the reply; its first line is above the viewport.
    final anchor = find.byKey(ValueKey('${_answer(101, '').key}#0'));
    expect(anchor, findsOneWidget);
    final before = tester.getTopLeft(anchor);
    for (var i = 31; i <= 40; i++) {
      await tester.pumpWidget(_harness(view(i)));
    }
    expect(tester.getTopLeft(anchor), before, reason: 'growth below the reader moves nothing above it');
  });

  testWidgets('loading an earlier page does not move what is on screen', (tester) async {
    final recent = _turns(20, 40);
    await tester.pumpWidget(_harness(SessionView(transcript: recent, historyLength: recent.length)));
    await tester.drag(find.byType(TranscriptView), const Offset(0, 600));
    await tester.pumpAndSettle();
    final anchor = find.byKey(ValueKey(recent[recent.length - 10].key));
    expect(anchor, findsOneWidget);
    final before = tester.getTopLeft(anchor);

    final all = [..._turns(0, 20), ...recent];
    await tester.pumpWidget(_harness(SessionView(transcript: all, historyLength: all.length)));
    expect(tester.getTopLeft(anchor), before);
  });

  testWidgets('a short transcript sits at the bottom and does not scroll', (tester) async {
    final items = _turns(0, 1);
    await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length)));
    final position = _position(tester);
    expect(position.maxScrollExtent - position.minScrollExtent, lessThanOrEqualTo(16));
    final answer = tester.getBottomLeft(find.byKey(ValueKey('${items.last.key}#0')));
    expect(answer.dy, greaterThan(800 - 60), reason: 'the newest row ends near the bottom edge');
  });

  testWidgets('a top-aligned transcript starts at the top, then follows its growth at the bottom', (tester) async {
    final items = _turns(0, 1);
    await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length), alignTop: true));
    final question = tester.getTopLeft(find.byKey(ValueKey(items.first.key)));
    expect(question.dy, lessThan(60), reason: 'the first row starts near the top edge');

    final grown = _turns(0, 30);
    await tester.pumpWidget(_harness(SessionView(transcript: grown, historyLength: grown.length), alignTop: true));
    await tester.pumpAndSettle();
    final position = _position(tester);
    expect(position.maxScrollExtent, greaterThan(0));
    expect(position.pixels, position.maxScrollExtent, reason: 'it stays at the bottom as it grows');
  });
}
