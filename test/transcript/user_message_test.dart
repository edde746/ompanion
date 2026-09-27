import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_core/store.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/chat/transcript/message_rows.dart';
import 'package:ompanion/screens/chat/transcript/transcript_actions.dart';
import 'package:ompanion/screens/chat/transcript/transcript_rows.dart';

void main() {
  late List<String> opened;
  late List<String> copied;

  setUp(() {
    opened = [];
    copied = [];
  });

  Future<void> pump(WidgetTester tester, String text, {bool shown = true}) => tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: TranscriptScope(
            actions: TranscriptActions(
              onCopy: copied.add,
              onOpenFile: (path, {line}) => opened.add(path),
              onOpenSubagent: (_) {},
            ),
            child: SingleChildScrollView(
              child: shown
                  ? TranscriptRowView(
                      row: ItemRow(UserItem(key: 'u1', timestamp: 1, content: [TextBlock(text)])),
                    )
                  : const SizedBox(),
            ),
          ),
        ),
      ),
    ),
  );

  final bubbleText = find.byWidgetPredicate((widget) => widget is Text && widget.textSpan != null);
  String shownText(WidgetTester tester) => tester.widget<Text>(bubbleText).textSpan!.toPlainText();

  testWidgets('mentions show as file names that open the file, and Copy still gives the message omp got', (
    tester,
  ) async {
    const message =
        'Please review these. @"/home/u/.omp/agent/sessions/-p/1/local/meeting notes.txt" @src/app.ts '
        'and local://paste-1.md';
    await pump(tester, message);

    expect(find.text('meeting notes.txt'), findsOneWidget);
    expect(find.text('app.ts'), findsOneWidget);
    expect(find.text('paste-1.md'), findsOneWidget);
    expect(shownText(tester), isNot(contains('/home/u')));
    expect(shownText(tester), isNot(contains('local://')));

    await tester.tap(find.text('meeting notes.txt'));
    await tester.tap(find.text('app.ts'));
    await tester.tap(find.text('paste-1.md'));
    await tester.pump();
    expect(opened, ['/home/u/.omp/agent/sessions/-p/1/local/meeting notes.txt', 'src/app.ts']);
    expect(find.text('local://paste-1.md'), findsOneWidget, reason: 'a local:// chip shows its path on tap');

    await tester.tap(find.byTooltip('Message actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy message'));
    await tester.pump();
    expect(copied, [message]);
  });

  testWidgets('a tagged model shows as a chip with its name and pseudonym, and Copy gives the tag omp got', (
    tester,
  ) async {
    const message = 'Have <model agent="m1" name="Fake Think"/> review this change';
    await pump(tester, message);

    expect(find.text('Fake Think'), findsOneWidget);
    expect(shownText(tester), isNot(contains('<model')));
    await tester.tap(find.text('Fake Think'));
    await tester.pump();
    expect(find.text('Subagent m1'), findsOneWidget, reason: 'the chip shows its pseudonym on tap');

    await tester.tap(find.byTooltip('Message actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy message'));
    await tester.pump();
    expect(copied, [message]);
  });

  testWidgets('the message actions button sits beside the bubble, not at the row edge', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pump(tester, 'first question');
    final button = tester.getRect(find.byTooltip('Message actions'));
    // The bubble's left edge is its text's left edge minus the bubble's 14 px horizontal padding.
    final bubbleLeft = tester.getRect(bubbleText).left - 14;
    expect(button.right, lessThanOrEqualTo(bubbleLeft));
    expect(
      bubbleLeft - button.right,
      lessThan(30),
      reason: 'the button hugs the bubble: a 4 px gap plus its own padding, not the row edge',
    );
  });

  testWidgets('a long message shows its first lines until the reader shows all, and stays open when rebuilt', (
    tester,
  ) async {
    final message = ['Look at this:', for (var i = 1; i < 40; i++) 'pasted line $i'].join('\n');
    await pump(tester, message);
    expect(shownText(tester), ['Look at this:', for (var i = 1; i < 6; i++) 'pasted line $i'].join('\n'));

    await tester.tap(find.text('Show all (40 lines)'));
    await tester.pump();
    expect(shownText(tester), message);
    expect(find.text('Show less'), findsOneWidget);

    await pump(tester, message, shown: false);
    await pump(tester, message);
    expect(shownText(tester), message);

    await tester.ensureVisible(find.text('Show less'));
    await tester.tap(find.text('Show less'));
    await tester.pump();
    expect(find.text('Show all (40 lines)'), findsOneWidget);
  });

  testWidgets('a long single line folds at a character limit and ends in an ellipsis', (tester) async {
    final message = 'word ' * 300;
    await pump(tester, message);
    final shown = shownText(tester);
    expect(shown.length, lessThanOrEqualTo(601));
    expect(shown, endsWith('word…'));
    expect(find.text('Show all (1 line)'), findsOneWidget);
  });

  testWidgets('a mention where the fold falls stays whole', (tester) async {
    final message = '${'x' * 590} @"/tmp/a long folder name/report.txt" ${'y' * 700}';
    await pump(tester, message);
    expect(find.text('report.txt'), findsOneWidget);
    expect(shownText(tester), isNot(contains('y')));
  });

  testWidgets('a message of twelve lines shows whole, without a toggle', (tester) async {
    final message = [for (var i = 0; i < 12; i++) 'line $i'].join('\n');
    await pump(tester, message);
    expect(shownText(tester), message);
    expect(find.textContaining('Show all'), findsNothing);
  });
}
