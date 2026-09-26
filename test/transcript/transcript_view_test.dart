import 'dart:math' as math;

import 'package:flutter/gestures.dart';
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

/// A settled turn [n] with content wider than the transcript, which scrolls sideways: a fenced code block and a `bash`
/// card with a multi-line command in its work, and a table in its answer.
List<TranscriptItem> _codeTurn(int n) {
  final start = n * 100000;
  final wide = 'x' * 300;
  final columns = [for (var c = 1; c < 8; c++) 'Output column $c'].join(' | ');
  final values = [for (var c = 1; c < 8; c++) 'value $c'].join(' | ');
  return [
    UserItem(entryId: 'u$n', timestamp: start, content: [TextBlock('Question $n')]),
    AssistantItem(
      entryId: 's$n',
      timestamp: start + 1000,
      content: [
        TextBlock('Checking $n.\n\n```dart\nconst fence$n = "$wide";\n```'),
        ToolCallBlock(id: 'c$n', name: 'bash', arguments: {'command': 'echo step-$n \\\n  $wide'}),
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
      content: [TextBlock(List.generate(6, (i) => 'out-$n line $i').join('\n'))],
    ),
    AssistantItem(
      entryId: 'a$n',
      timestamp: start + 4000,
      content: [TextBlock('Answer $n.\n\n| Step | $columns |\n|${'---|' * 8}\n| cell-$n | $values |\n\nDone with $n.')],
      provider: 'fake',
      model: 'fake-1',
      stopReason: StopReason.stop,
      duration: const Duration(seconds: 8),
    ),
  ];
}

/// Scrolls the transcript toward its bottom ([down]) or its top with the mouse wheel or trackpad pans until it stops
/// moving.
Future<void> _scrollToEdge(
  WidgetTester tester, {
  required bool down,
  PointerDeviceKind kind = PointerDeviceKind.mouse,
}) async {
  const at = Offset(500, 400);
  final position = _position(tester);
  final pointer = TestPointer(kind == PointerDeviceKind.mouse ? 1 : 2, kind);
  if (kind == PointerDeviceKind.mouse) await tester.sendEventToBinding(pointer.hover(at));
  for (var i = 0; i < 200; i++) {
    final before = position.pixels;
    if (kind == PointerDeviceKind.mouse) {
      await tester.sendEventToBinding(pointer.scroll(Offset(0, down ? 400 : -400)));
    } else {
      // Fingers moving up scroll toward the bottom.
      await tester.sendEventToBinding(pointer.panZoomStart(at));
      for (var step = 1; step <= 4; step++) {
        await tester.sendEventToBinding(pointer.panZoomUpdate(at, pan: Offset(0, (down ? -100.0 : 100.0) * step)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await tester.sendEventToBinding(pointer.panZoomEnd());
    }
    await tester.pumpAndSettle();
    if (position.pixels == before) return;
  }
  fail('the transcript kept moving');
}

/// Turns the mouse wheel up until [finder] is on screen, then brings its last match to the middle of the view.
Future<void> _wheelUpTo(WidgetTester tester, Finder finder) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(pointer.hover(const Offset(500, 400)));
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -200)));
    await tester.pumpAndSettle();
  }
  expect(finder, findsWidgets);
  await tester.sendEventToBinding(pointer.scroll(Offset(0, tester.getCenter(finder.last).dy - 400)));
  await tester.pumpAndSettle();
}

/// Shows [turns] as a session brings them: each turn's items arrive one by one while its run works, then it settles.
/// Items that arrive once the transcript overflows go in the center sliver.
Future<List<TranscriptItem>> _grow(WidgetTester tester, List<List<TranscriptItem>> turns) async {
  var items = <TranscriptItem>[];
  for (final turn in turns) {
    for (var count = 1; count <= turn.length; count++) {
      final shown = [...items, ...turn.take(count)];
      await tester.pumpWidget(
        _harness(SessionView(transcript: shown, historyLength: shown.length, run: const RunState(running: true))),
      );
    }
    items = [...items, ...turn];
    await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length)));
    await tester.pumpAndSettle();
  }
  return items;
}

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

  testWidgets('a table that scrolls sideways leaves the transcript alone: no earlier page is asked for, and at the '
      'bottom the jump-to-latest button stays hidden', (tester) async {
    var loads = 0;
    final actions = TranscriptActions(
      onCopy: (_) {},
      onOpenFile: (path, {line}) {},
      onOpenSubagent: (_) {},
      onLoadEarlier: () async => loads++,
    );
    final items = [for (var n = 1; n <= 20; n++) ..._codeTurn(n)];
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: TranscriptView(view: SessionView(transcript: items, historyLength: items.length), actions: actions),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final jump = find.ancestor(of: find.byTooltip(t.transcript.jumpToLatest), matching: find.byType(AnimatedScale));
    expect(tester.widget<AnimatedScale>(jump).scale, 0);

    // The newest answer's table, at the bottom edge, to its right end and back.
    final table = tester.state<ScrollableState>(
      find.byWidgetPredicate((widget) => widget is Scrollable && widget.axisDirection == AxisDirection.right).last,
    );
    for (final to in [table.position.maxScrollExtent, 0.0]) {
      table.position.jumpTo(to);
      await tester.pumpAndSettle();
      expect(tester.widget<AnimatedScale>(jump).scale, 0, reason: 'the transcript is still at its bottom');
    }
    expect(loads, 0, reason: 'the transcript is thousands of pixels from its top');
  });

  testWidgets('a short transcript sits at the bottom and does not scroll', (tester) async {
    final items = _turns(0, 1);
    await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length)));
    final position = _position(tester);
    expect(position.maxScrollExtent - position.minScrollExtent, lessThanOrEqualTo(16));
    final answer = tester.getBottomLeft(find.byKey(ValueKey('${items.last.key}#0')));
    expect(answer.dy, greaterThan(800 - 60), reason: 'the newest row ends near the bottom edge');
  });

  testWidgets('the scroll extent stays steady while the wheel scrolls up through rows of very different heights',
      (tester) async {
    // Runs of one-line answers alternate with runs of answers holding a 30-line code block, so the rows around the
    // viewport are all short, then all tall.
    final code = ['```dart', for (var line = 0; line < 30; line++) 'final value$line = compute($line);', '```'].join('\n');
    final items = [
      for (var n = 0; n < 160; n++) ...[_user(n * 2), _answer(n * 2 + 1, (n ~/ 20).isEven ? 'Short answer $n.' : code)],
    ];
    await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length)));
    final position = _position(tester);
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(const Offset(500, 400)));
    var range = position.maxScrollExtent - position.minScrollExtent;
    var worst = 0.0;
    for (var step = 0; step < 2000 && position.pixels > position.minScrollExtent; step++) {
      await tester.sendEventToBinding(pointer.scroll(const Offset(0, -300)));
      await tester.pump();
      final next = position.maxScrollExtent - position.minScrollExtent;
      worst = math.max(worst, (next - range).abs() / range);
      range = next;
    }
    expect(position.pixels, position.minScrollExtent, reason: 'the wheel reached the first row');
    // The scrollbar thumb's length is the viewport's share of this range, so it changes with it.
    expect(worst, lessThan(0.01), reason: 'no wheel step changed the scroll range by 1 % or more');
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

    testWidgets('a turn opened or closed in a session that grew turn by turn stays where it is, and the reader then '
        'reaches the first row and the bottom, where the transcript follows its growth again', (tester) async {
      var items = await _grow(tester, [for (var n = 1; n <= 12; n++) _codeTurn(n)]);
      final position = _position(tester);
      // Turn 6 arrived after the transcript overflowed: it sits in the center sliver.
      final summary = find.byKey(const ValueKey('u6#turn'));
      final first = find.byKey(ValueKey(items.first.key));

      for (final (index, open) in [true, false].indexed) {
        await _wheelUpTo(tester, summary);
        final at = tester.getTopLeft(summary);
        await tester.tap(find.descendant(of: summary, matching: find.byType(InkWell)), kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(_markdown('Checking 6.'), open ? findsOneWidget : findsNothing);
        expect(tester.getTopLeft(summary), at, reason: 'the toggled row stays where it is');
        await tester.pumpAndSettle();

        for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.trackpad]) {
          await _scrollToEdge(tester, down: false, kind: kind);
          expect(position.pixels, position.minScrollExtent);
          expect(tester.getTopLeft(first).dy, lessThan(60), reason: 'the first row meets the top edge ($kind)');

          await _scrollToEdge(tester, down: true, kind: kind);
          expect(position.pixels, position.maxScrollExtent);
          final newest = find.byKey(ValueKey('${items.last.key}#0'));
          expect(tester.getBottomLeft(newest).dy, greaterThan(800 - 60), reason: 'the newest row ends at the bottom');
        }

        final prompt = _user(1000 + index * 2);
        items = [...items, prompt];
        await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length)));
        await tester.pumpAndSettle();
        for (var i = 1; i <= 8; i++) {
          final streaming = [...items, _answer(1001 + index * 2, _paragraphs(i), streaming: true)];
          const run = RunState(running: true);
          await tester.pumpWidget(_harness(SessionView(transcript: streaming, historyLength: items.length, run: run)));
          expect(position.pixels, position.maxScrollExtent, reason: 'update $i stays at the bottom');
        }
        items = [...items, _answer(1001 + index * 2, _paragraphs(8))];
        await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length)));
        await tester.pumpAndSettle();
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a mouse selection in an open turn\'s code and in a table works, also once it scrolled away and the '
        'reader selects elsewhere', (tester) async {
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      // A press held past the tap deadline, a drag, then Cmd+C.
      Future<void> selectAndCopy(Offset from, Offset to) async {
        final gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
        await tester.pump(const Duration(milliseconds: 300));
        await gesture.moveTo(to);
        await tester.pump();
        await gesture.up();
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.pump();
      }

      final items = [for (var n = 1; n <= 20; n++) ..._codeTurn(n)];
      await tester.pumpWidget(_harness(SessionView(transcript: items, historyLength: items.length)));
      final summary = find.byKey(const ValueKey('u10#turn'));
      await _wheelUpTo(tester, summary);
      await tester.tap(find.descendant(of: summary, matching: find.byType(InkWell)), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();

      // The bash card's command, then the answer's table, both in views that scroll sideways.
      for (final text in ['echo step-10', 'cell-10']) {
        final target = find.textContaining(text, findRichText: true);
        await _wheelUpTo(tester, target);
        final start = tester.getTopLeft(target.last) + const Offset(2, 8);
        await selectAndCopy(start, start + const Offset(60, 0));
        expect(copied, startsWith(text.substring(0, 4)));

        // The row holding the selection is off screen now. A press under the last row passes every row that can take
        // the selection on its way there, the one off screen too; the drag ends at the start of the newest answer.
        await _scrollToEdge(tester, down: true);
        await selectAndCopy(const Offset(300, 795), tester.getTopLeft(_markdown('Done with 20.')) + const Offset(2, 8));
        expect(copied, startsWith('Done with 20.'));
      }
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

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

    testWidgets('revealing an entry before the loaded history loads earlier pages until it arrives', (tester) async {
      final turns = TurnExpansion();
      // Each page ends in a long answer, so the reader is far from the top and no page loads on its own.
      final pages = [
        for (var n = 1; n <= 4; n++) [..._workedTurn(n), _user(n * 100000 + 50000), _answer(n * 100000 + 60000, _paragraphs(80))],
      ];
      var loaded = 1;
      List<TranscriptItem> shown() => [for (final page in pages.skip(pages.length - loaded)) ...page];
      final view = ValueNotifier(SessionView(transcript: shown(), historyLength: shown().length));
      var loads = 0;
      final actions = TranscriptActions(
        onCopy: (_) {},
        onOpenFile: (path, {line}) {},
        onOpenSubagent: (_) {},
        onLoadEarlier: () async {
          loads++;
          loaded++;
          view.value = SessionView(transcript: shown(), historyLength: shown().length);
        },
      );
      await tester.pumpWidget(
        TranslationProvider(
          child: MaterialApp(
            home: Scaffold(
              body: ValueListenableBuilder<SessionView>(
                valueListenable: view,
                builder: (context, value, _) => TranscriptView(view: value, actions: actions, turns: turns),
              ),
            ),
          ),
        ),
      );
      turns.reveal('r2');
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump();
      }
      expect(loads, 2, reason: 'turn 2 is two pages back');
      expect(turns.pendingReveal, isNull, reason: 'the turn holding r2 was opened');
    });
  });
}
