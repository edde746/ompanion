import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/store.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/chat/transcript/images.dart';
import 'package:ompanion/screens/chat/transcript/markdown.dart';
import 'package:ompanion/screens/chat/transcript/tool_card.dart';
import 'package:ompanion/screens/chat/transcript/transcript_actions.dart';
import 'package:ompanion/screens/chat/transcript/transcript_rows.dart';
import 'package:ompanion/sessions/machine_images.dart';

import '../sessions/fake_image_host.dart';

const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=';

void main() {
  late Directory temp;
  late FakeImageHost host;
  late MachineImages loader;
  late List<String> opened;
  final modified = DateTime.utc(2026, 9, 1);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('chat images ');
    host = FakeImageHost();
    loader = MachineImages(cacheDir: () async => temp);
    opened = [];
  });

  tearDown(() => temp.deleteSync(recursive: true));

  HostImageBytes png({bool preview = true, int size = 4 << 20}) => HostImageBytes(
    bytes: base64Decode(_png),
    mimeType: 'image/png',
    size: size,
    modified: modified,
    preview: preview,
    width: 3000,
    height: 2000,
  );

  Future<void> pump(WidgetTester tester, Widget child, {bool machine = true, Key? key}) => tester.pumpWidget(
    TranslationProvider(
      child: MaterialApp(
        home: Scaffold(
          body: TranscriptScope(
            key: key,
            actions: TranscriptActions(
              onCopy: (_) {},
              onOpenFile: (path, {line}) => opened.add(path),
              onOpenSubagent: (_) {},
              images: machine ? SessionImages(loader, host, cwd: '/home/u/proj') : null,
            ),
            child: SingleChildScrollView(child: child),
          ),
        ),
      ),
    ),
  );

  /// Lets the loader's file I/O, which fake async does not run, finish.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
  }

  group('machine images in markdown', () {
    testWidgets('load on their own, fitted, with name, size and Open in Files', (tester) async {
      host.files['/home/u/proj/out/chart.png'] = (size: 4 << 20, modified: modified);
      host.answers['/home/u/proj/out/chart.png'] = png();
      await pump(tester, const TranscriptMarkdown('Here:\n\n![chart](out/chart.png)'));
      expect(find.text('Loading chart.png…'), findsOneWidget);

      await settle(tester);
      expect(host.fetches, [('/home/u/proj/out/chart.png', false)]);
      expect(
        tester.widget<Image>(find.descendant(of: find.byType(FittedImage), matching: find.byType(Image))).image,
        isA<MemoryImage>(),
      );
      expect(find.text('chart.png · 3000×2000 · preview, 68 B of 4.0 MB'), findsOneWidget);

      await tester.tap(find.text('Open in Files'));
      expect(opened, ['out/chart.png']);
      await tester.tap(find.descendant(of: find.byType(FittedImage), matching: find.byType(Image)));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('a rebuilt transcript shows a loaded image at once, without fetching again', (tester) async {
      host.files['/home/u/proj/a.png'] = (size: 4 << 20, modified: modified);
      host.answers['/home/u/proj/a.png'] = png();
      await pump(tester, const TranscriptMarkdown('![](a.png)'));
      await settle(tester);
      await pump(tester, const TranscriptMarkdown('![](a.png)'), key: const ValueKey('rebuilt'));
      expect(find.byType(FittedImage), findsOneWidget);
      expect(find.textContaining('Loading'), findsNothing);
      await settle(tester);
      expect(host.fetches, hasLength(1));
    });

    testWidgets('a file too large to send on its own offers its original, loaded on request', (tester) async {
      host.files['/home/u/big.png'] = (size: 12 << 20, modified: modified);
      host.answers['/home/u/big.png'] = HostImageProblem(HostImageIssue.tooLarge, size: 12 << 20, modified: modified);
      host.originals['/home/u/big.png'] = png(preview: false, size: 12 << 20);
      await pump(tester, const TranscriptMarkdown('![](~/big.png)'));
      await settle(tester);
      expect(find.text('~/big.png (12.0 MB) is too large to load on its own'), findsOneWidget);
      expect(find.byType(FittedImage), findsNothing);

      await tester.tap(find.text('Load original (12.0 MB)'));
      await settle(tester);
      expect(find.byType(FittedImage), findsOneWidget);
      expect(host.fetches, [('/home/u/big.png', false), ('/home/u/big.png', true)]);
    });

    testWidgets('missing and unreadable files say so', (tester) async {
      host.files['/secret.png'] = (size: 10, modified: modified);
      host.answers['/secret.png'] = const HostImageProblem(HostImageIssue.denied);
      await pump(tester, const TranscriptMarkdown('![](gone.png)\n\n![](/secret.png)'));
      await settle(tester);
      expect(find.text('Image not found: gone.png'), findsOneWidget);
      expect(find.text('No permission to read /secret.png'), findsOneWidget);
    });
  });

  group('tool cards', () {
    ToolCard card(
      String tool, {
      Map<String, Object?> args = const {},
      List<ContentBlock> content = const [],
      Object? details,
    }) {
      final result = ToolResultItem(
        toolCallId: 'call-1',
        toolName: tool,
        args: args,
        content: content,
        details: details,
        state: ToolState.done,
      );
      return ToolCard(
        data: ToolData(row: ToolRow.orphan(result), result: result, subagents: const []),
      );
    }

    testWidgets('an image read shows the image, open, with its size and type', (tester) async {
      await pump(
        tester,
        card(
          'read',
          args: {'path': 'pic.png'},
          content: const [
            TextBlock('Read image file [image/png]'),
            ImageBlock(data: _png, mimeType: 'image/png'),
          ],
          details: {
            'fileSize': 26672,
            'meta': {
              'source': {'type': 'path', 'value': '/home/u/proj/pic.png'},
            },
          },
        ),
      );
      expect(find.byType(FittedImage), findsOneWidget);
      expect(find.text('1×1'), findsOneWidget);
      expect(find.text('PNG'), findsOneWidget);
      expect(find.text('Read image file [image/png]'), findsNothing);
      await tester.tap(find.descendant(of: find.byType(FittedImage), matching: find.byType(Image)));
      await tester.pumpAndSettle();
      expect(find.byType(InteractiveViewer), findsOneWidget);
    });

    testWidgets('a text read stays closed until tapped', (tester) async {
      await pump(
        tester,
        card(
          'read',
          args: {'path': 'notes.md'},
          content: const [TextBlock('alpha\nbeta')],
          details: {
            'displayContent': {'text': 'alpha\nbeta', 'startLine': 1},
            'totalLines': 2,
          },
        ),
      );
      expect(find.textContaining('alpha', findRichText: true), findsNothing);
      await tester.tap(find.text('read'));
      await tester.pump();
      expect(find.textContaining('alpha', findRichText: true), findsWidgets);
    });

    testWidgets("an image read by a model without image input shows the file from the machine", (tester) async {
      host.files['/home/u/proj/pic.png'] = (size: 26672, modified: modified);
      host.answers['/home/u/proj/pic.png'] = png(preview: false, size: 26672);
      await pump(
        tester,
        card(
          'read',
          args: {'path': 'pic.png'},
          content: const [TextBlock('Image metadata:\n- MIME: image/png\n- Dimensions: 640x360')],
          details: {
            'fileSize': 26672,
            'meta': {
              'source': {'type': 'path', 'value': '/home/u/proj/pic.png'},
            },
          },
        ),
      );
      await settle(tester);
      expect(find.textContaining('Image metadata'), findsOneWidget);
      expect(find.byType(FittedImage), findsOneWidget);
      expect(host.fetches, [('/home/u/proj/pic.png', false)]);
    });

    testWidgets('todo and web search results keep images that come without their usual details', (tester) async {
      for (final tool in ['todo', 'web_search']) {
        await pump(
          tester,
          card(
            tool,
            content: const [ImageBlock(data: _png, mimeType: 'image/png')],
          ),
          key: ValueKey(tool),
        );
        expect(find.byType(TranscriptImage), findsOneWidget, reason: tool);
      }
    });
  });
}
