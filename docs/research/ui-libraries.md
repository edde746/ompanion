# UI libraries: markdown, highlighting, transcript list, terminal, editor

Today's Flutter stable is 3.47.5 (2026-09-18, Dart 3.13.4); this project targets 3.47.1. Versions and dates come from the pub.dev API. Stars and activity come from the GitHub API. **[INFERENCE]** marks claims I did not verify. The Dart snippets are sketches; I did not run any of them.

---
## 1. Markdown for the streaming chat

| | gpt_markdown 1.3.0 | flutter_markdown_plus 1.0.12 | markdown_widget 2.3.2+8 | Our own renderer on markdown 7.3.1 |
|---|---|---|---|---|
| Published | 2026-09-20 | 2026-07-10 | 2025-04-26 | 2026-03-18 |
| License | BSD-3 | BSD-3 | MIT | BSD-3 [INFERENCE] |
| Minimum SDK / Flutter | >=3.7 / >=3.32 | ^3.4 / >=3.27.1 | >=3.0 / none | ^3.9.0 |
| Activity | 182★, 46 open issues, last push 2026-09-21. CI on the stable channel passed on 2026-09-20; stable was 3.47.5 then [INFERENCE] | 69★, 102 open, last push 2026-07-10 | 458★, 46 open, last push 2026-01-17 | Maintained by the Dart team |
| Parser | Its own hand-written parser ("plusparse"), not CommonMark | `markdown` (GitHub-flavored) | `markdown` | `markdown` |
| Cost per update | Finished segments are cached and reused; only the unfinished tail is re-parsed. It still compares the whole text on each update (linear in length). | Any data change triggers a full `_parseMarkdown()` (widget.dart:364-368). Every paragraph gets `Text.rich(key: UniqueKey())` (builder.dart:999), so all text widgets are rebuilt from scratch on every update. | Full re-render on every update | Up to us |
| Author's own benchmark: time per chunk with a 12 KB reply (debug VM) | 3.4 ms (`GptMarkdown`), 1.3 ms (`SliverGptMarkdown`) | 49.3 ms | 57.0 ms | — |
| Unclosed code fence while streaming | Rendered as a code block, and the code builder receives `closed: false` | CommonMark runs an unclosed fence to the end of the document, so it renders as code | Same | Same |
| Text selection across blocks | Wrap in `SelectionArea`; each block is its own widget. Selection is unstable only while the reveal animation runs. | `selectable: true` makes each paragraph a separate `SelectableText`, so no cross-block selection. `SelectionArea` with `selectable: false` should work [INFERENCE], but the selection is lost on every update because of the UniqueKeys. | Has "select all and copy" | Our design |
| Code block hook | `codeBuilder(ctx, lang, code, closed)` | `syntaxHighlighter.format(String)`, or `builders{'pre': …}` | `PreConfig(wrapper:)` | Ours |
| Tables | Built in; columns sized to content; horizontal scroll; `tableBuilder` | Built in | Built in | Ours |
| LaTeX | Built in via flutter_math_fork. `\(..\)` and `\[..\]` always work; `$` needs `useDollarSignsForLatex`. `latexBuilder` to replace. | Separate package flutter_markdown_plus_latex 1.0.5 | Only as example code, not in the package | flutter_math_fork plus our own syntax rules |
| Images | `imageBuilder(ctx, url, w, h)`, `onImageTap` | `imageBuilder(uri, title, alt)` | `ImgConfig` | Ours |
| Links | `onLinkTap(url, title)`, `inlineLinkBuilder`; bare URLs linked by default; `autolinkSchemes` for app schemes | `onTapLink` | `LinkConfig` | Ours |
| Custom syntax | `blockComponents` (a `MarkdownBlockSyntax`, tried before the built-in rules), `inlinePatterns`, `inlineDirectives` | `blockSyntaxes` and `inlineSyntaxes` plus `builders` | `SpanNodeGeneratorWithTag` | Anything |

**Math package.** Use flutter_math_fork 0.7.4 (2025-05-21, Apache-2.0, 103★, 56 open, last push 2026-06-02). It is the TeX renderer both candidates use. It relies on `RenderObjectWithLayoutCallbackMixin`, which still exists and is not deprecated in Flutter stable (`rendering/object.dart:4291`). Two pull requests adding support for newer Flutter (#122, #127) are unmerged, so upstream is slow. If a Flutter release breaks it, point `dependency_overrides` at a git fork.

### Recommendation: gpt_markdown 1.3.0
It already works the way our stream does: you pass the full text so far on each update, it reuses the finished segments and rebuilds only the tail. `message_update` also sends the full text each time.

How to integrate it:
- **One list item per transcript entry**, keyed with `ValueKey(entry.id)`. A finished entry renders `GptMarkdown(isStreaming: false)` from immutable data and never rebuilds. `isStreaming` defaults to `true`, so pass `false` for history.
- **The streaming entry owns a `ValueNotifier<String>`.** The reducer writes the latest full text into it at most once per frame. Only that entry's `ValueListenableBuilder` rebuilds; the list itself never rebuilds per token.
- **Use `animation: GptMarkdownAnimation.none`.** No animation ticker runs, and selection stays stable in finished segments.
- **Keep builders and component lists in top-level or `static final` fields.** The package caches by object identity, so a new list on every build defeats the cache.
- **Supply our own `codeBuilder`.** The built-in code widget highlights the whole block on the UI thread on every build, and has an open crash when the copy button is used after disposal (#146).
- **If a very long finished message is slow to appear**, split it with the public `splitStreamSegments` and make each segment its own list item [INFERENCE].

```dart
import 'package:gpt_markdown/gpt_markdown.dart';

// Kept at top level: gpt_markdown's caches compare these by identity.
final List<MarkdownBlockComponent> kBlocks = [
  MarkdownBlockComponent(syntax: const CommonMarkFence('`'), builder: _fence),
  MarkdownBlockComponent(syntax: const CommonMarkFence('~'), builder: _fence),
];
Widget _fence(BuildContext c, MdCustomBlock n, GptMarkdownConfig cfg) =>
    TranscriptCode(language: n.data as String, code: n.body, closed: n.closed);

Widget assistantText(String text, bool streaming) => GptMarkdown(
      text,
      isStreaming: streaming,
      animation: GptMarkdownAnimation.none,
      blockComponents: kBlocks,
      useDollarSignsForLatex: true, // decide in the M3 spike (risk 2)
      onLinkTap: (url, title) => openLink(url),
      imageBuilder: (c, url, w, h) => TranscriptImage(url: url, width: w, height: h),
    );

// The streaming entry: only this subtree rebuilds per token.
ValueListenableBuilder<String>(
  valueListenable: entry.liveText, // set at most once per frame
  builder: (_, text, __) => assistantText(text, true),
);
```

A CommonMark-style fence rule. It handles `~~~`, fences longer than three characters, and nested fences. The package's segment splitter also follows registered rules.
```dart
final class CommonMarkFence extends MarkdownBlockSyntax {
  const CommonMarkFence(this.char);
  final String char; // '`' or '~'
  @override String get type => 'fence$char';
  @override String get prefix => char * 3;
  static final _open = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');
  @override
  MarkdownBlockMatch? parse(List<String> lines, int start) {
    final m = _open.firstMatch(lines[start]);
    if (m == null || m[1]![0] != char) return null;
    final info = m[2]!.trim();
    if (char == '`' && info.contains('`')) return null;
    final close = RegExp('^ {0,3}${RegExp.escape(char)}{${m[1]!.length},}[ \\t]*\$');
    var end = start + 1;
    while (end < lines.length && !close.hasMatch(lines[end])) end++;
    final closed = end < lines.length;
    return MarkdownBlockMatch(
      node: MdCustomBlock(type: type, body: lines.sublist(start + 1, end).join('\n'),
          closed: closed, data: info.split(RegExp(r'\s+')).first),
      endLine: closed ? end + 1 : end);
  }
}
```

**Risks**
1. **The parser is not CommonMark.** Its built-in fence knows only ```` ``` ````, ignores `~~~`, and closes at any line that starts with ```` ``` ````. Nested four-backtick fences, which LLMs emit often, therefore break (`plusparse/block_parser.dart:52-70`). The fence rule above fixes fences. Other differences (lists, setext headings, emphasis edge cases) need a conformance check against recorded omp transcripts in the M3 spike.
2. **`$` math is off by default.** Turning it on risks treating `$` in normal prose as math (issue #108).
3. **The benchmarks are the author's own, run on the debug VM.** The M3 gate needs profile-mode numbers on a mid-range phone.
4. **Partial Markdown flickers while it streams.** A table's header row shows as a paragraph until the `|---|` row arrives. With animation off, an unclosed `**` shows as literal asterisks until it closes [INFERENCE].
5. **1.3.0 is a five-day-old rewrite with 46 open issues.** Pin the exact version. It also pulls in `highlight` 0.7.0 (2021) and a bundled font even though we won't use them.

**Fallback: our own renderer on `markdown` 7.3.1**, if the conformance check fails. The builder alone is 1,000+ lines (compare flutter_markdown_plus `builder.dart`). We would also write our own splitting of finished vs unfinished text, since `markdown`'s tree carries no source offsets [INFERENCE], plus tables, math and selection. Separately, 7.3.1 can take quadratic time on a long run of unbroken word characters (a long hash or base64 string, for example). The fix exists only in the unreleased `7.4.1-wip` (CHANGELOG). flutter_markdown_plus and markdown_widget are exposed to the same bug.

---
## 2. Syntax highlighting: re_highlight 0.0.3
| | re_highlight 0.0.3 | highlight / flutter_highlight 0.7.0 | highlighting 0.9.0+11.8.0 | syntax_highlight 0.5.0 |
|---|---|---|---|---|
| Published | 2024-02-05 | 2021-03-07 | 2023-05-05 | 2025-08-19 |
| How it works | Port of highlight.js v11.9.0; its README says it passes the upstream tests | Older highlight.js port | highlight.js 11.8 port | VS Code TextMate grammars (not tree-sitter) |
| Languages | About 190 files in `lib/languages`, including bash, diff and dart | About 190 | About 190 | 15. Missing bash/shell, C/C++, C#, Ruby, PHP and diff. |
| Other | MIT, 84★, 4 open, last push 2025-03-18. The same engine re_editor uses, which runs it in an isolate. | Unmaintained. gpt_markdown still pulls in `highlight`. | Unmaintained | BSD-3. Requires async asset loading. Pulls in `super_clipboard` → `super_native_extensions`, a native build. |

I found no published speed benchmark. It is a regex engine, so cost grows with code length [INFERENCE]; measure it in the spike.

Policy:
- While a fence is still open, show plain monospace text. Highlight once it closes.
- Run highlighting in one long-lived worker isolate and cache results by language and a hash of the code.
- Keep large tool output (read, bash) truncated behind "show more".

The isolate returns plain records, which are safe to send between isolates:
```dart
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/languages/all.dart';

typedef Run = ({int end, String? scope});
final class _Runs implements HighlightRenderer { // interface: lib/src/renderer.dart
  final runs = <Run>[]; final _s = <String?>[]; var _pos = 0;
  @override void addText(String t) { _pos += t.length; runs.add((end: _pos, scope: _s.isEmpty ? null : _s.last)); }
  @override void openNode(DataNode n) => _s.add(n.scope); // field name per token_tree.dart [INFERENCE]
  @override void closeNode(DataNode n) => _s.removeLast();
}
Highlight? _hl; // one instance per worker isolate
List<Run> highlightRuns(String code, String lang) {
  final r = _Runs();
  (_hl ??= Highlight()..registerLanguages(builtinAllLanguages))
      .highlight(code: code, language: lang) // exact signature: lib/src/highlight.dart [INFERENCE]
      .render(r);
  return r.runs;
}
```
On the UI side, turn the runs into `TextSpan`s:
- Pick the theme by brightness, for example `Theme.of(ctx).brightness == Brightness.dark ? atomOneDarkTheme : atomOneLightTheme`. These are `Map<String, TextStyle>` from `lib/styles`.
- Look up the full scope name first, then its first dot-separated part [INFERENCE].
- Override the root background with `ColorScheme.surfaceContainerHighest` and the default text colour with `onSurface`, so blocks match Material 3.
- Highlighting only changes colours, so block height does not change when it lands.

---
## 3. Transcript list: Flutter's built-in slivers, no package

**`ListView.builder(reverse: true)`** 
- What you get for free: the list opens at the bottom, stays there while at the bottom, and older pages can be added at the far end without a jump.
- The problem: when the user has scrolled up but the streaming message is still within the laid-out area (viewport plus cache), each bit of growth pushes everything above it. Scroll offsets are measured from the bottom, so what the user is reading drifts.
- flutter_chat_ui 2.12.0 uses reversed lists and fixes the drift with scrollview_observer 1.27.3 (MIT, 2026-09-14, 620★, 3 open). Its "generative" mode requires calling `standby(mode: ChatScrollObserverHandleMode.generative)` before every update.

**Packages I would not use**
- **super_sliver_list 0.4.1** (released 2024-03-26, last push 2024-07-24, MIT, 427★, 33 open). The maintainer wrote on 2025-12-12: "haven't had much time". Crash bugs are open in `getOffsetToReveal` and `addTrailingChild` (#67, #70). Nobody has reported build failures on 2025–26 Flutter versions, but nothing shows it tested on 3.47, so it is unverified. Only worth adding if we need exact jump-to-index across unbuilt items of varying height.
- **scrollable_positioned_list 0.3.8** (2023-05-08). Its repository, google/flutter.widgets, is archived with 258 open issues.
- **flutter_list_view 1.1.29** (2024-12-17, 62★). Stale.

Flutter has no built-in scroll anchoring (flutter#99158 is still open). Keep every entry's height fixed by its data: reserve space for images up front, and make highlighting a colour-only change.

**Recommendation: two slivers around a center anchor, plus a custom ScrollPhysics.**
- **Top sliver (before the anchor):** history loaded when the session opens, plus older pages, ordered newest first. It grows upward, so loading older messages is just `older.addAll(page)` with no jump.
- **Bottom sliver (the anchor):** entries that arrive after opening: prompts, the streaming reply, tool cards. It grows downward, so growth never moves anything above it.
- **`anchor: 1.0`** puts scroll position 0 at the bottom edge of the viewport, so the list opens at the bottom with no height estimates.
- **The physics keeps the view at the bottom inside layout**, so there is no one-frame lag. Flutter calls `adjustPositionForNewDimensions` from `applyContentDimensions` → `correctForNewDimensions` (scroll_position.dart:642-702).
- **Jumping to any entry** (session tree, search): rebuild the window with that entry first in the bottom sliver. It lands exactly, with no estimation.

```dart
final class StickToBottomPhysics extends ScrollPhysics {
  const StickToBottomPhysics({super.parent});
  @override StickToBottomPhysics applyTo(ScrollPhysics? a) => StickToBottomPhysics(parent: buildParent(a));
  @override
  double adjustPositionForNewDimensions({required ScrollMetrics oldPosition,
      required ScrollMetrics newPosition, required bool isScrolling, required double velocity}) {
    final pinned = oldPosition.pixels >= oldPosition.maxScrollExtent - 32;
    if (pinned && !isScrolling) return newPosition.maxScrollExtent;
    return super.adjustPositionForNewDimensions(oldPosition: oldPosition,
        newPosition: newPosition, isScrolling: isScrolling, velocity: velocity);
  }
}

SelectionArea(
  child: CustomScrollView(
    controller: _scroll,
    center: const ValueKey('live'),
    anchor: 1.0,
    physics: StickToBottomPhysics(parent: ScrollConfiguration.of(context).getScrollPhysics(context)),
    slivers: [
      SliverList.builder( // history, newest first; grows upward
        itemCount: older.length,
        itemBuilder: (_, i) => EntryTile(key: ValueKey(older[i].id), entry: older[i])),
      SliverList.builder( // new entries, oldest first; grows downward
        key: const ValueKey('live'),
        itemCount: live.length,
        itemBuilder: (_, i) => EntryTile(key: ValueKey(live[i].id), entry: live[i])),
    ],
  ),
);
```
Risks:
- This is our own code. The M3 spike must cover a fling near the bottom, the keyboard opening and closing, desktop window resizing, and iOS bounce.
- `SelectionArea` can only select entries that are currently built.
- Fallback if this design fails: `reverse: true` plus scrollview_observer.

---
## 4. Terminal: xterm3 6.3.4
**xterm3 6.3.4** (2026-09-24, AGPL-3.0-or-later, Flutter >=3.19)
- Repo klc/xterm3, created 2026-08-06, 1★, 0 open issues, one maintainer.
- CI runs on the stable and master channels on macOS; it passed for 6.3.4.

**xterm2 5.2.0** (2026-07-25, MIT, 5★)
- Its repo lists a 5.3.0 in the changelog that was never published.
- The xterm3 README says the public API is unchanged from xterm2, so the two are interchangeable.

**Performance (numbers from the xterm3 README).** Setup: AOT build, M1 Pro, 170×50 grid, 32 MiB of output.
- Plain ASCII: 113 MiB/s (xterm2 87, xterm 16).
- Cyrillic: 90 MiB/s (xterm2 5.5).
- Scrollback memory for 10k lines at 170 columns: 52.8 MiB (xterm2 79.3).

**API**
- `Terminal(maxLines:, onOutput:, onResize: (w,h,pw,ph), onReply:, onTitleChange:, onBell:, inputHandler:)`.
- `write(String)` takes text, not bytes, and must not be called re-entrantly. `paste(String)` cleans the text before sending.
- `TerminalView(terminal, controller:, autofocus:, keyboardType:, deleteDetection:, hardwareKeyboardOnly:, readOnly:, textStyle:, theme:, onSecondaryTapDown:)`.

**Keyboard input (IME)**
- IME composition is held back until the keyboard commits it.
- On Android, set `deleteDetection: true`.
- Call `commitComposing()` before sending keys from an extra-keys bar. The example `VirtualKeyboard` shows Ctrl/Alt toggles through `inputHandler`.

**Selection, search, links**
- Selection: `TerminalController.selection`, then `terminal.buffer.getText(sel)`.
- Search: `Terminal.search`. OSC 8 hyperlinks are supported.

**Optional `PacedTerminalWriter`:** parses at most 8 ms of output per frame, so a burst drains about 50% slower but the view stays at 75 fps.

```dart
const _utf8 = Utf8Decoder(allowMalformed: true); // the default decoder errors on bad bytes
final terminal = Terminal(maxLines: 10000);

Future<SSHSession> openShell(SSHClient client) async { // dartssh2 4.1.0
  await WidgetsBinding.instance.endOfFrame; // wait until TerminalView has sized the grid
  final s = await client.shell(pty: SSHPtyConfig(
      width: terminal.viewWidth, height: terminal.viewHeight)); // terminal type defaults to xterm-256color
  s.stdout.cast<List<int>>().transform(_utf8).listen(terminal.write); // with a PTY, stderr arrives merged into stdout
  terminal.onOutput = (d) => s.write(utf8.encode(d));
  terminal.onResize = (w, h, pw, ph) => s.resizeTerminal(w, h, pw, ph);
  return s;
}
```
**Local shell on desktop.** Use flutter_pty2 2.0.0 (2026-09-19, MIT, 1★), pinned exactly.
- It is a clean-slate API with backpressure, Windows ConPTY with a Job Object that contains child processes, and all output drained before `done` completes.
- The alternative, flutter_pty 0.4.2 (2025-01-06), has been unmaintained since then. Open issues include a duplicated program name in Windows arguments (#19), a 1-second sleep on Windows (#20) and 1 KB reads (#24).
- flutter_pty2's 1.x line keeps flutter_pty's old API if 2.0 misbehaves.

```dart
final pty = await Pty.spawn(PtySpawnOptions(
  executable: Platform.environment['SHELL'] ?? '/bin/zsh', arguments: const ['-l'],
  size: PtySize(columns: terminal.viewWidth, rows: terminal.viewHeight)));
pty.output.cast<List<int>>().transform(_utf8).listen(terminal.write);
terminal.onOutput = (d) => pty.input.write(utf8.encode(d));
terminal.onResize = (w, h, pw, ph) =>
    pty.resize(PtySize(columns: w, rows: h, pixelWidth: pw, pixelHeight: ph));
// Teardown: pty.kill(); await pty.done; await pty.close();
```
**License (not legal advice)**
- **GPLv3 §13:** "you have permission to link or combine any covered work with a work licensed under version 3 of the GNU Affero General Public License … the special requirements of the GNU Affero General Public License, section 13, concerning interaction through a network will apply to the combination as such."
- **AGPL §13:** that extra duty applies when someone modifies the program and users interact with it "remotely through a computer network". omp-app runs on the user's own device, so in practice only the normal GPLv3 duty to offer source applies.
- **Keep xterm3's files:** `LICENSE`, `LICENSE.MIT` and `NOTICE`.

**App Store risk (§9 plans iOS and Mac App Store builds)**
- In 2010 the FSF held that App Store terms are "further restrictions" on the GPL, and GNU Go was pulled from the store. GPLv3 §10 has the same rule: "You may not impose any further restrictions".
- The project can grant an App Store exception for its own code under GPLv3 §7. It cannot do that for klc's xterm3.
- Options for the store builds:
  - Build them with xterm2 5.2.0 (MIT, same API) behind a D16 build flag.
  - Get written permission from xterm3's author.
  - Leave the terminal out of store builds.

**Other risks**
- One maintainer, and the repo is seven weeks old; pin the exact version.
- `write` takes decoded text, so every data source needs the tolerant decoder.

---
## 5. Code viewer/editor and diffs

**re_editor 0.10.0** (2026-07-01, MIT, 762★, 39 open, last push 2026-08-21)
- `CodeEditor` options: `controller`, `readOnly`, `showCursorWhenReadOnly`, `wordWrap`, `maxLengthSingleLineRendering` (for minified files), `findBuilder` / `findController`, `indicatorBuilder`, `style: CodeEditorStyle(codeTheme: CodeHighlightTheme(...))`, `chunkAnalyzer`, `shortcutsActivatorsBuilder`, `toolbarController`.
- Highlighting runs in an isolate (`_code_highlight.dart:175-184`).
- Find and replace logic is built in; we supply the find-panel UI.
- Its README says it is "specifically optimized for large texts".
```dart
CodeEditor(
  controller: CodeLineEditingController.fromText(content),
  readOnly: true, wordWrap: false, maxLengthSingleLineRendering: 2000,
  style: CodeEditorStyle(fontFamily: 'JetBrains Mono', fontSize: 13,
    codeTheme: CodeHighlightTheme(
      languages: {'dart': CodeHighlightThemeMode(mode: langDart)},
      theme: isDark ? atomOneDarkTheme : atomOneLightTheme)),
  indicatorBuilder: (ctx, ec, cc, n) => Row(children: [
    DefaultCodeLineNumber(controller: ec, notifier: n),
    DefaultCodeChunkIndicator(width: 20, controller: cc, notifier: n)]),
  findBuilder: (ctx, c, readOnly) => FindPanel(controller: c, readOnly: readOnly),
);
```
Risks:
- **Flutter 3.47 is untested.** 0.10.0 was published before Flutter 3.47.0 and the repo has no CI. 0.9.0 had to fix a build error on Flutter 3.44.
- **Fixes on main are unreleased:** a layout loop, PageUp/PageDown, and a highlighting failure when the theme lists no languages (#123-#125). If we hit these, depend on a git commit.
- **Old dependency pin:** `isolate_manager ^4.1.5+1`, while the latest is 6.3.2. That conflicts with anything else needing 5 or later.
- **Huge files over SFTP:** set a size cap before opening in the editor [INFERENCE].

**Diffs**
- **Transcript edit cards:** omp already sends the diff. The edit result's `details.diff` comes from native `editDiffString`, a "numbered unified diff". The TUI parses each line with `^([+-\s])(\s*\d+)\|(.*)$` (plus a legacy form) in `tui/src/chrome/diff.ts:39-47`. It marks changed words within replaced lines with `diffWords`.
- **Files dock, diff against git:** run `git diff --no-color --no-ext-diff -U3 -- <path>` over exec and parse the unified diff hunks.
- **Word-level diff:**
  - Use dartdiff 1.0.0 (2026-02-27, MIT, 0★). It ports jsdiff (`diffWords`, `diffLines`, `structuredPatch`, `parsePatch`, `applyPatch`), which matches what omp's TUI does. Its README says it runs jsdiff's own test corpus. It has one release, so we can vendor it if needed.
  - Fallback: diff_match_patch 0.4.1 (2021-06-03, Apache-2.0). Its SDK constraint `>=2.12 <3.0` should still resolve under Dart 3 [INFERENCE].
- **Diff widgets:** don't use the existing ones.
  - flutter_diff_viewer 1.4.0: repo created 2026-08-18, 0★.
  - diffine 1.0.0: 2026-09-12, 0★.
  - deviation 0.1.0: its README warns it is still a work in progress.
  
  Render rows ourselves in a `SliverList` (line-number gutter, +/− marker, re_highlight colours).
```dart
sealed class DiffRow { const DiffRow(this.line, this.text); final int? line; final String text; }
final class Same extends DiffRow { const Same(super.l, super.t); }
final class Added extends DiffRow { const Added(super.l, super.t); }
final class Removed extends DiffRow { const Removed(super.l, super.t); }
final _omp = RegExp(r'^([+\- ])(\s*\d+)\|(.*)$');
DiffRow? parseOmpDiffLine(String s) {
  final m = _omp.firstMatch(s);
  if (m == null) return null; // then try the legacy form, as the TUI does
  final n = int.tryParse(m[2]!.trim());
  return switch (m[1]) { '+' => Added(n, m[3]!), '-' => Removed(n, m[3]!), _ => Same(n, m[3]!) };
}
```

---
## Decisions to record
| Area | Choice | Version, date | License |
|---|---|---|---|
| Markdown | gpt_markdown, with the CommonMark fence rule, our own `codeBuilder`, and `animation: none` | 1.3.0, 2026-09-20 | BSD-3 |
| Math | flutter_math_fork (via gpt_markdown) | 0.7.4, 2025-05-21 | Apache-2.0 |
| Highlighting | re_highlight, run in an isolate | 0.0.3, 2024-02-05 | MIT |
| Transcript list | Built-in `CustomScrollView` with center anchor and `StickToBottomPhysics`; fallback scrollview_observer | Fallback: 1.27.3, 2026-09-14 | MIT |
| Terminal | xterm3; xterm2 in App Store builds | 6.3.4, 2026-09-24 / 5.2.0, 2026-07-25 | AGPL-3.0+ / MIT |
| Local PTY | flutter_pty2 | 2.0.0, 2026-09-19 | MIT |
| Editor | re_editor | 0.10.0, 2026-07-01 | MIT |
| Word diff | dartdiff | 1.0.0, 2026-02-27 | MIT |

**M3 spike checks**
- Replay recorded omp transcripts: nested fences, `~~~` fences, lists, tables and `$` math, compared against the TUI's rendering.
- Profile-mode frame times on a mid-range phone, streaming a 50 KB reply at 60 updates per second.
- Scrolling behaviour: fling near the bottom, keyboard, iOS bounce.
- A build of re_editor on Flutter 3.47.

---
## Performance

The transcript meets the frame budget while a long reply streams into a long session. Measured on macOS
(Apple silicon, profile build) with `integration_test/transcript_benchmark_test.dart` (command in README):
2,000 synthetic items (questions, `bash` calls with results, markdown answers with code and tables), then a
12,385-character markdown reply streamed in 300 updates at 50 per second.

| | Build p50 | Build p90 | Build p99 | Build max | Frames over 16.7 ms |
|---|---|---|---|---|---|
| Before | 12.92 ms | 23.44 ms | 106.80 ms | 162.66 ms | 72 of 296 |
| After | 1.34 ms | 2.34 ms | 7.08 ms | 8.15 ms | 0 of 476 |

Raster after: p90 1.30 ms, max 8.80 ms. The "before" run used an earlier harness with the same data and
rate that also rebuilt its own window chrome on every update, so part of the difference is harness overhead.

What changed:
- **Rows are kept incrementally** (`TranscriptRowModel`). An update skips the unchanged leading items by
  identity and recomputes rows only from the first changed item. Row positions and tool results are indexed
  as rows are appended. Before, every update rebuilt the row list, `SessionView.toolResults` and a key-to-index
  map over the whole transcript.
- **Long text blocks are split into rows** of at most 1,500 characters, cut between markdown segments
  (`splitStreamSegments` with the fence rule). A streaming reply then rebuilds, lays out and repaints only its
  last part. Before, the whole reply was one list item that was laid out and repainted on every update.
- Coalescing is not needed in the app: `SessionViewBuilder` rebuilds through `setState`, so several views in
  one frame produce one build.
