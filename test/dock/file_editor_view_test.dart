import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/files/file_workspace.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/dock/files/file_editor_view.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:re_editor/re_editor.dart';

void main() {
  late Directory temp;
  late String root;
  late FileWorkspace workspace;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('file-editor-');
    root = temp.path;
    final link = LocalLink(environment: {'HOME': root});
    final probe = HostProbe(
      commandShell: CommandShell.posix,
      os: HostOs.macos,
      kernel: 'Darwin',
      arch: 'arm64',
      home: root,
      agentDir: '$root/.omp/agent',
    );
    workspace = FileWorkspace()..connect = () async => (link, probe);
  });

  tearDown(() {
    workspace.dispose();
    temp.deleteSync(recursive: true);
  });

  /// Lets the file I/O and git processes the app started finish: they complete outside the test's fake time, and
  /// starting a process waits for a zero-length timer inside it.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 200 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump(Duration.zero);
    }
  }

  /// The editor of [path] as the Files tab shows it: rebuilt whenever the workspace changes.
  Future<void> pumpEditor(WidgetTester tester, String path) async {
    await tester.runAsync(() => workspace.open(path));
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: ListenableBuilder(
              listenable: workspace,
              builder: (context, _) => FileEditorView(workspace: workspace, document: workspace.current!),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets(
    'Cmd+S with the cursor in the editor saves the file',
    (tester) async {
      final path = '$root/notes.txt';
      File(path).writeAsStringSync('one\n');
      await pumpEditor(tester, path);
      await tester.tap(find.byType(CodeEditor));
      // The editor requests focus from a zero-length timer.
      await tester.pump(Duration.zero);
      workspace.current!.controller.text = 'one\ntwo\n';
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await settle(tester, () => File(path).readAsStringSync() == 'one\ntwo\n');

      expect(File(path).readAsStringSync(), 'one\ntwo\n');
      await settle(tester, () => !workspace.current!.saving);
      expect(workspace.current!.dirty, isFalse);
      await tester.pumpWidget(const SizedBox());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('the find bar covers only its own rows: the text below it stays on screen and reachable', (tester) async {
    final path = '$root/main.dart';
    File(path).writeAsStringSync([for (var i = 1; i <= 40; i++) 'line $i'].join('\n'));
    await pumpEditor(tester, path);
    final t = tester.element(find.byType(FileEditorView)).t.dock.fileBrowser;

    await tester.tap(find.byTooltip(t.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.find));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, t.find), 'line 1');
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.widgetWithText(TextField, t.find));
    final editor = tester.getRect(find.byType(CodeEditor));

    // A tap well below the bar lands in the text and moves the cursor off the first line.
    await tester.tapAt(Offset(editor.center.dx, bar.bottom + (editor.bottom - bar.bottom) / 2));
    await tester.pumpAndSettle();
    expect(workspace.current!.controller.selection.baseIndex, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('reloading from disk while the git diff shows keeps the editor usable', (tester) async {
    Future<void> git(List<String> args) async {
      final result = await Process.run('git', [
        '-c',
        'user.name=Test',
        '-c',
        'user.email=test@example.com',
        '-c',
        'commit.gpgsign=false',
        ...args,
      ], workingDirectory: root);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    final path = '$root/README.md';
    File(path).writeAsStringSync('# Demo\n');
    await tester.runAsync(() async {
      await git(['init', '-q']);
      await git(['add', 'README.md']);
      await git(['commit', '-q', '-m', 'init']);
      File(path).writeAsStringSync('# Demo\nchanged\n');
      await workspace.follow(root);
      await workspace.refreshGit();
    });
    await pumpEditor(tester, path);
    final t = tester.element(find.byType(FileEditorView)).t.dock.fileBrowser;

    await tester.tap(find.byTooltip(t.showDiff));
    await settle(tester, () => find.textContaining('changed').evaluate().isNotEmpty);
    expect(find.textContaining('changed'), findsWidgets);

    File(path).writeAsStringSync('# Demo\nchanged again\n');
    await tester.tap(find.byTooltip(t.more));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.reload));
    await settle(tester, () => workspace.current!.controller.text.contains('again'));
    await settle(tester, () => find.textContaining('changed again').evaluate().isNotEmpty);

    expect(tester.takeException(), isNull);
    expect(find.byType(ErrorWidget), findsNothing);
    expect(find.byTooltip(t.backToFiles), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
