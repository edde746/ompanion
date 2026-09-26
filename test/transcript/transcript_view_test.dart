import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/chat/transcript/message_rows.dart';
import 'package:ompanion/screens/chat/transcript/transcript_view.dart';
import 'package:ompanion/sessions/turn_expansion.dart';
import 'package:omp_core/store.dart';

import 'fixtures.dart';

final _actions = TranscriptActions(
  onBranchFrom: (_) {},
  onCopy: (_) {},
  onOpenFile: (path, {line}) {},
  onOpenSubagent: (_) {},
);

Widget _harness(SessionView view, {bool alignTop = false, TurnExpansion? turns, Key? key}) => TranslationProvider(
  child: MaterialApp(
    home: Scaffold(
      body: TranscriptView(key: key, view: view, actions: _actions, alignTop: alignTop, turns: turns),
    ),
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

/// A settled turn [n]: a question, a step that runs `bash`, its result, and the answer, 12 s from question to answer.
List<TranscriptItem> _workedTurn(int n) {
  final start = n * 100000;
  return [
    UserItem(entryId: 'u$n', timestamp: start, content: [TextBlock('Question $n')]),
    AssistantItem(
      entryId: 's$n',
      timestamp: start + 1000,
      content: [
        TextBlock('Checking $n.'),
        ToolCallBlock(id: 'c$n', name: 'bash', arguments: {'command': 'echo step-$n'}),
      ],
      provider: 'fake',
      model: 'fake-1',
      stopReason: StopReason.toolUse,
    ),
    ToolResultItem(
      entryId: 'r$n',
      toolCallId: 'c$n',
      toolName: 'bash',
      state: ToolState.done,
      timestamp: start + 3000,
      content: [TextBlock('step-$n')],
    ),
    AssistantItem(
      entryId: 'a$n',
      timestamp: start + 4000,
      content: [TextBlock('Answer $n.')],
      provider: 'fake',
      model: 'fake-1',
      stopReason: StopReason.stop,
      duration: const Duration(seconds: 8),
    ),
  ];
}

Finder _markdown(String text) => find.textContaining(text, findRichText: true);

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
        // Open every folded turn, then every collapsed card and summary in it, so every body renders once.
        for (var round = 0; round < 4; round++) {
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

  testWidgets('the top of a reply that overflowed while streaming shows its first rows at the top edge', (tester) async {
    final history = _turns(0, 1);
    final prompt = _user(100);
    await tester.pumpWidget(_harness(SessionView(transcript: [...history, prompt], historyLength: history.length)));
    for (var i = 1; i <= 30; i++) {
      final transcript = [...history, prompt, _answer(101, _paragraphs(i), streaming: true)];
      await tester.pumpWidget(_harness(SessionView(transcript: transcript, historyLength: history.length)));
    }
    final position = _position(tester);
    position.jumpTo(position.minScrollExtent);
    await tester.pump();
    final first = tester.getTopLeft(find.byKey(ValueKey(history.first.key)));
    expect(first.dy, lessThan(60), reason: 'the first question starts near the top edge, not under a blank viewport');
    expect(tester.getTopLeft(find.byKey(ValueKey(prompt.key))).dy, lessThan(800 / 2));
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

  testWidgets('an ask waiting for its answer shows one line, and the answer once it came', (tester) async {
    const call = ToolCallBlock(
      id: 'c1',
      name: 'ask',
      arguments: {
        'i': 'Asking for a choice',
        'questions': [
          {
            'id': 'pick',
            'question': 'Which option should the demo take?',
            'options': [
              {'label': 'Option A'},
              {'label': 'Option B'},
            ],
          },
        ],
      },
    );
    final asking = AssistantItem(
      timestamp: 2,
      content: const [call],
      provider: 'fake',
      model: 'fake-1',
      stopReason: StopReason.toolUse,
    );
    // The run goes on while the ask waits and after it is answered.
    SessionView view(ToolResultItem result) =>
        SessionView(transcript: [_user(1), asking, result], historyLength: 3, run: const RunState(running: true));

    await tester.pumpWidget(
      _harness(view(ToolResultItem(toolCallId: 'c1', toolName: 'ask', state: ToolState.running))),
    );
    expect(find.text(t.transcript.tool.askWaiting), findsOneWidget);
    expect(find.textContaining('Which option should the demo take?'), findsNothing);
    expect(find.textContaining('Option A'), findsNothing);

    await tester.pumpWidget(
      _harness(
        view(
          ToolResultItem(
            toolCallId: 'c1',
            toolName: 'ask',
            state: ToolState.done,
            content: const [TextBlock('User answers:\npick: Option A')],
            details: const {
              'results': [
                {
                  'id': 'pick',
                  'question': 'Which option should the demo take?',
                  'options': ['Option A', 'Option B'],
                  'selectedOptions': ['Option A'],
                },
              ],
            },
          ),
        ),
      ),
    );
    expect(find.text(t.transcript.tool.askWaiting), findsNothing);
    expect(find.textContaining('Option A'), findsOneWidget);
    expect(find.textContaining('Option B'), findsOneWidget);
  });

  group('folded turns', () {
    testWidgets('a summary row opens and closes its turn by tap and by keyboard, and stays where it is', (tester) async {
      final items = [for (var n = 1; n <= 12; n++) ..._workedTurn(n)];
      await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length)));
      expect(_markdown('Answer 12.'), findsOneWidget);
      expect(_markdown('Checking 12.'), findsNothing);
      expect(find.textContaining('echo step-12'), findsNothing);
      // The summary row of turn n; its key is the turn's first item's.
      Finder summary(int n) => find.byKey(ValueKey('u$n#turn'));
      Finder label(int n) => find.descendant(of: summary(n), matching: find.text('Worked for 12s  ·  1 tool call'));
      expect(label(12), findsOneWidget);

      // The newest turn, at the bottom edge: the transcript does not follow the bottom as the turn opens.
      final at = tester.getTopLeft(summary(12));
      await tester.tap(label(12));
      await tester.pumpAndSettle();
      expect(_markdown('Checking 12.'), findsOneWidget);
      expect(find.textContaining('echo step-12'), findsOneWidget);
      expect(tester.getTopLeft(summary(12)), at);

      // An older turn above it.
      final olderAt = tester.getTopLeft(summary(11));
      await tester.tap(label(11));
      await tester.pumpAndSettle();
      expect(_markdown('Checking 11.'), findsOneWidget);
      expect(tester.getTopLeft(summary(11)), olderAt);

      Focus.of(tester.element(label(11))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(_markdown('Checking 11.'), findsNothing);
      expect(tester.getTopLeft(summary(11)), olderAt);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(_markdown('Checking 11.'), findsOneWidget);
    });

    testWidgets('the latest turn shows every row while the session works on it, and folds once it settles', (
      tester,
    ) async {
      final items = [..._workedTurn(1), ..._workedTurn(2)];
      SessionView view({required bool running, List<UiRequest> requests = const []}) => SessionView(
        transcript: items,
        historyLength: items.length,
        run: RunState(running: running),
        requests: requests,
      );
      await tester.pumpWidget(_harness(view(running: true)));
      expect(_markdown('Checking 2.'), findsOneWidget);
      expect(find.textContaining('echo step-2'), findsOneWidget);
      expect(find.textContaining('Worked for'), findsOneWidget, reason: 'only the first turn folds');

      await tester.pumpWidget(
        _harness(view(running: false, requests: const [ConfirmRequest('q1', title: 'Go on?', message: '')])),
      );
      expect(_markdown('Checking 2.'), findsOneWidget, reason: 'an open request keeps the turn open');

      await tester.pumpWidget(_harness(view(running: false)));
      expect(_markdown('Checking 2.'), findsNothing);
      expect(find.textContaining('echo step-2'), findsNothing);
      expect(find.textContaining('Worked for'), findsNWidgets(2));
      expect(_markdown('Answer 2.'), findsOneWidget);
    });

    testWidgets('turns the reader opened stay open when the chat switches sessions and back', (tester) async {
      final turnsA = TurnExpansion();
      final turnsB = TurnExpansion();
      final a = SessionView(transcript: _workedTurn(1), historyLength: 4);
      final b = SessionView(transcript: _workedTurn(2), historyLength: 4);
      await tester.pumpWidget(_harness(a, turns: turnsA, key: const ValueKey('a')));
      await tester.tap(find.textContaining('Worked for'));
      await tester.pumpAndSettle();
      expect(_markdown('Checking 1.'), findsOneWidget);

      await tester.pumpWidget(_harness(b, turns: turnsB, key: const ValueKey('b')));
      expect(_markdown('Checking 2.'), findsNothing);

      await tester.pumpWidget(_harness(a, turns: turnsA, key: const ValueKey('a')));
      expect(_markdown('Checking 1.'), findsOneWidget);
    });

    testWidgets('revealing an entry opens the turn that holds it, also when the transcript brings it later', (
      tester,
    ) async {
      final turns = TurnExpansion();
      final items = [..._workedTurn(1), ..._workedTurn(2)];
      await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length), turns: turns));
      turns.reveal('r1');
      await tester.pump();
      expect(_markdown('Checking 1.'), findsOneWidget);
      expect(_markdown('Checking 2.'), findsNothing);

      // The tree navigated to an entry that the rebuilt transcript brings afterwards.
      turns.reveal('s3');
      await tester.pump();
      final more = [...items, ..._workedTurn(3)];
      await tester.pumpWidget(_harness(SessionView(transcript: more, historyLength: more.length), turns: turns));
      expect(_markdown('Checking 3.'), findsOneWidget);
      expect(_markdown('Checking 2.'), findsNothing);
    });
  });
}
