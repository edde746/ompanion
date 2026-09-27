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
      // Not `useDollarSignsForLatex`: it also rewrites inline code. The app rewrites `$…$` and `$$…$$`
      // itself (`rewriteDollarMath`, lib/screens/chat/transcript/markdown.dart).
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
- **super_sliver_list 0.4.1** (released 2024-03-26, last push 2024-07-24, MIT, 427★, 33 open; still the latest on pub.dev on 2026-09-26). The maintainer wrote on 2025-12-12: "haven't had much time". Crash bugs are open in `getOffsetToReveal` and `addTrailingChild` (#67, #70). Nobody has reported build failures on 2025–26 Flutter versions, but nothing shows it tested on 3.47, so it is unverified. Its per-item extent estimation is what the transcript needed for a steady scrollbar; Flutter's own `SliverChildDelegate.estimateMaxScrollOffset` hook gives the same without the package (see "Performance").
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
## 4. Terminal: xterm2 5.2.0

**xterm2 5.2.0** (2026-07-25, MIT, 5★) is the terminal in every build, iOS and Android included.
- Home repo SoFluffyOS/xterm2; the 5.2.0 changelog is the maintained fork's own (rename in 5.0.0, Unicode 17 widths
  and Kitty keyboard modifiers in 5.1.0, bounded search and cheaper cell copies in 5.2.0).
- Its repo lists a 5.3.0 in the changelog that was never published; 5.2.0 is the newest on pub.dev (checked
  2026-09-26).
- Pin it exactly if a 5.3.0 ever appears: the API is small but `TerminalView`'s widget API is where a fork can
  drift.

**xterm3 6.3.4** (2026-09-24, AGPL-3.0-or-later) is in no build. AGPL-3.0 code cannot be conveyed through the App
Store by anyone but its copyright holder: the project publishes its own GPLv3 code as that holder, but it holds no
rights in klc's. Two forks of the same 4.0.0 base, one licence apart, is not a trade worth carrying, so one terminal
serves all builds.

**What xterm3 has that xterm2 does not.** Compared library by library (its `core.dart`, `ui.dart` and `zmodem.dart`
against xterm2's): `TerminalUrlDetection`, `RenderStats`, and `PacedTerminalWriter`. Every other difference is
private: the public classes ompanion uses — `Terminal`, `TerminalView`, `TerminalController`, `TerminalTheme`,
`TerminalStyle`, `TerminalTargetPlatform`, `SelectionMode`, `BufferRange`/`CellOffset` — have identical signatures.
xterm3 also spells `Buffer.onLineEvicted`, `TerminalStyle.enableLigatures`, `Terminal.onUnknownSequence`,
`TerminalView.predictionText` and a few scroll/prompt intents differently; ompanion uses none of them.
- `TerminalUrlDetection`: unused. The view's own OSC 8 `onHyperlinkTap` exists in both, and that is what ompanion
  opens links with.
- `RenderStats`: unused (xterm3's own benchmark support).
- `PacedTerminalWriter`: **used**, so ompanion has its own `lib/terminal/frame_writer.dart` for the same job,
  queueing PTY output and spreading it over frames. It is ompanion's code under ompanion's licence, not a copy of
  xterm3's version, which is AGPL-3.0 and could not ship either. Details below.

**Performance (numbers from the xterm3 README; xterm2 is slower).** Setup: AOT build, M1 Pro, 170×50 grid, 32 MiB of
output.
- Plain ASCII: xterm3 113 MiB/s, xterm2 87, xterm 16.
- Cyrillic: xterm3 90 MiB/s, xterm2 5.5.
- Scrollback memory for 10k lines at 170 columns: xterm3 52.8 MiB, xterm2 79.3.

The Cyrillic figure is xterm3's widest lead; nothing in this project has measured a difference in the app, and
ompanion's own frame writer (below) is what keeps frames flowing under a burst.

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
- Search: `TerminalSearch`. OSC 8 hyperlinks are supported.
- OSC 52: xterm2's `TerminalView` answers a program's clipboard read with the device clipboard whenever the
  terminal has focus, unless the `Terminal` has its own `onClipboardQuery`. ompanion's answers null, so reads are
  refused and writes (a remote editor's yank) still reach the clipboard (`lib/terminal/terminal_session.dart`).

**ompanion's `TerminalFrameWriter`.** xterm2 has no equivalent, so `lib/terminal/frame_writer.dart` queues PTY
output and parses it for at most 8 ms per frame, in slices of 4 Ki UTF-16 code units, carrying the rest over
frames scheduled with `SchedulerBinding.scheduleFrameCallback`: a transient callback runs at the start of a frame,
before build and layout, so what it parses paints in that same frame, and it can be unregistered in `dispose`,
which a post-frame callback cannot. The budget is time, not characters: 64 Ki code units cost xterm2's parser
0.7 ms of ASCII but 10.4 ms of emoji, 10.5 ms of CJK and 12.8 ms of Cyrillic (JIT, M3), so a character count that
keeps Cyrillic inside a frame throttles ASCII, and one that suits ASCII freezes on Cyrillic. A PTY delivers a
burst as many chunks between two frames, so the budget counts all parsing since the last frame. A slice never ends
between the two code units of a surrogate pair (xterm2 decodes a code point only within one `write`); an escape
sequence cut by a slice is fine, because xterm2's `EscapeParser` keeps an unfinished sequence across `write` calls.
Output arriving at an idle writer goes through at once, so typing echo pays no frame. More than 256 Ki queued code
units pause the output stream (flutter_pty2 stops reading the PTY, dartssh2 stops granting channel window) until
the frames have carried the backlog: a shell that writes faster than the terminal draws blocks, as in any
terminal, and the prompt after Ctrl-C does not wait behind megabytes. While the app is hidden no frames run, so the
writer then parses output as it arrives. `dispose()` unregisters the callback and drops what is queued. It is
written here, not copied from xterm3 (which is AGPL-3.0), and is covered by ompanion's own licence.

Measured here (macOS 26, M3, profile build, 1100×800 window, a real local PTY and an SSH channel to the Docker
test target; before = 64 Ki code units per frame without back-pressure; after = two runs; frame intervals
p50/p99/max):

| Output | Before | After |
|---|---|---|
| local `seq 1 200000` | 0.59 s; 17/70/70 ms | 0.58–1.0 s; 17/41–55/41–55 ms |
| local `cat` 20 MB ASCII | 5.2 s; 17/20/23 ms | 1.0–1.8 s; 19–21/26–32/26–32 ms |
| local `cat` 2.5 M code units of Cyrillic | 1.6 s; 37/57/57 ms | 0.9–2.3 s; 17/21–23/21–26 ms |
| local `yes` for 3 s, Ctrl-C, then the prompt | 31.7 s; 49/159/193 ms | 0.2–1.2 s; 17/18–31/19–38 ms |
| SSH `seq 1 200000` | 1.1 s; 43/214/214 ms | 0.5–0.7 s; 17/18–86/18–86 ms |
| SSH `cat` 20 MB ASCII | 7.5 s; 17/28/2187 ms | 1.4–3.5 s; 17–21/95–232/95–232 ms |
| SSH `cat` 2.5 M code units of Cyrillic | 1.8 s; 35/425/425 ms | 1.1–2.6 s; 17/86–157/86–198 ms |
| SSH `yes` for 3 s, Ctrl-C, then the prompt | 42.5 s; 69/171/270 ms | 1.0–1.7 s; 17/27–68/108–212 ms |

An SSH channel that the far end fills faster than the terminal parses shows 80–100 ms gaps every few frames: each
resume lets dartssh2 grant its whole 2 MiB window back, the target sends it at once, and dartssh2 decrypts it on
the UI isolate [INFERENCE from the gap pattern; without back-pressure the same transfer has no gaps but queues
without bound, which is the 42 s above]. A link slower than the parser never pauses the channel.

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
**Local shell on desktop.** Use flutter_pty2 2.0.0 (2026-09-19, MIT, 1★). `pubspec.yaml` allows `^2.0.0`;
`pubspec.lock` holds 2.0.0.
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
**Licence (not legal advice).** xterm2 is MIT: the copyright notice and the licence text travel with the app, and
nothing about it conflicts with an app store. That is the whole point of the switch — the previous AGPL-3.0
terminal could not be conveyed through the App Store by anyone but its own copyright holder, and the project holds
the rights to ompanion's code only, not a third party's. `docs/research/licenses.md` records the licence of every
resolved package.

**Other risks**
- One maintainer on each fork. `pubspec.yaml` allows `xterm2: ^5.2.0` and `flutter_pty2: ^2.0.0`, so
  `flutter pub upgrade` takes a new minor release; `pubspec.lock` (CI installs with `--enforce-lockfile`) holds
  the versions in use.
- `write` takes decoded text, so every data source needs the tolerant decoder.
- `paste()` replaces ESC and other control bytes with a space and converts `\n` to `\r`; when the program has asked
  for bracketed paste (bash 5 on a remote host does), a paste that ends in a newline is inserted into the line
  editor and does not run until Return is pressed. Both are the same in xterm3.

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
- **Flutter 3.47:** re_editor 0.10.0 builds and its widget test runs on Flutter 3.47.1 in CI (`test/dock/file_editor_view_test.dart`). 0.10.0 was published before 3.47.0; 0.9.0 had to fix a build error on Flutter 3.44.
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
## Decisions
| Area | Choice | Version, date | License |
|---|---|---|---|
| Markdown | gpt_markdown, with the CommonMark fence rule, our own `codeBuilder`, and `animation: none` | 1.3.0, 2026-09-20 | BSD-3 |
| Math | flutter_math_fork (via gpt_markdown) | 0.7.4, 2025-05-21 | Apache-2.0 |
| Highlighting | re_highlight, run in an isolate | 0.0.3, 2024-02-05 | MIT |
| Transcript list | Built-in `CustomScrollView` with center anchor and `StickToBottomPhysics`; fallback scrollview_observer | Fallback: 1.27.3, 2026-09-14 | MIT |
| Terminal | xterm2, one build for every platform | 5.2.0, 2026-07-25 | MIT |
| Local PTY | flutter_pty2 | 2.0.0, 2026-09-19 | MIT |
| Editor | re_editor | 0.10.0, 2026-07-01 | MIT |
| Word diff | dartdiff | 1.0.0, 2026-02-27 | MIT |

**M3 checks**
- Done: a build of re_editor on Flutter 3.47 (`test/dock/file_editor_view_test.dart` runs on Flutter 3.47.1 in CI), and the markdown renderer (the decisions table above; `lib/screens/chat/transcript/markdown.dart`).
- Still open: replay recorded omp transcripts (nested fences, `~~~` fences, lists, tables and `$` math) against the TUI's rendering; profile-mode frame times on a mid-range phone streaming a 50 KB reply at 60 updates per second; fling near the bottom, keyboard and iOS bounce.

---
## Performance

The transcript meets the frame budget while a long reply streams into a long session. Measured on macOS
(Apple silicon, profile build) with `integration_test/transcript_benchmark_test.dart` (command in README):
2,000 synthetic items (questions, `bash` calls with results, markdown answers with code and tables), then a
12,385-character markdown reply streamed in 300 updates at 50 per second. The session's run works on the last
turn while the reply streams into it and settles with the last update, so the 499 settled turns are folded and
the last turn folds inside the measured frames.

| | Build p50 | Build p90 | Build p99 | Build max | Frames over 16.7 ms |
|---|---|---|---|---|---|
| Before incremental rows | 12.92 ms | 23.44 ms | 106.80 ms | 162.66 ms | 72 of 296 |
| Incremental rows | 1.34 ms | 2.34 ms | 7.08 ms | 8.15 ms | 0 of 476 |
| Incremental rows, measured again (median of 3 runs, alternating with the next row) | 0.93 ms | 2.15 ms | 6.64 ms | 8.90 ms | 0 of 469 |
| Folded turns (median of 3 runs) | 0.94 ms | 2.27 ms | 6.40 ms | 8.96 ms | 0 of 468 |
| Per-row scroll extents (2 runs each, alternating with the same code without them: 1.51/2.59/5.84/9.46 and 1.64/2.75/7.63/11.03 ms) | 0.97 / 1.24 ms | 1.85 / 2.23 ms | 5.83 / 4.94 ms | 9.30 / 5.29 ms | 0 of 465 / 473 |

Raster with folded turns: p90 1.30 ms, max 2.96 ms (medians). Over 10 runs with folded turns and 8 without, no
frame took more than 16.7 ms, and each build had one run with a single 12 ms frame. The build max comes from the
same frames with and without folding: the eight frames in which the reply starts a new 1,500-character row, and
the frame of the final update, which with folding also folds the last turn (6.4 to 8.0 ms). A settled last turn
that a run resumes without a new user message unfolds in one frame of 11 to 14 ms (the same benchmark with the run
starting at the first update). The "before" run used an earlier harness with the same data and rate that also
rebuilt its own window chrome on every update, so part of that difference is harness overhead.

The row model itself (`flutter test`, debug VM, the same 2,000 items): the first update takes 0.44 ms with and
without folding and shows 2,000 rows instead of 2,500; an update of the reply streaming into the live last turn
takes 0.05 ms; opening the first turn, which shows every turn after it again, takes 0.44 ms.

What changed:
- **Rows are kept incrementally** (`TranscriptRowModel`). An update skips the unchanged leading items by
  identity and recomputes rows only from the first changed item. Row positions and tool results are indexed
  as rows are appended. Before, every update rebuilt the row list, `SessionView.toolResults` and a key-to-index
  map over the whole transcript.
- **Long text blocks are split into rows** of at most 1,500 characters, cut between markdown segments
  (`splitStreamSegments` with the fence rule). A streaming reply then rebuilds, lays out and repaints only its
  last part. Before, the whole reply was one list item that was laid out and repainted on every update.
- **Settled turns fold in the same model** (`TranscriptRowModel.isOpen`). While the run works on the last turn,
  that turn shows every row and a streaming update cuts and appends rows from the changed item as before. An
  update that settles a turn, and a toggle, show the rows from that turn's start again. A turn's summary row
  compares equal while its facts and open state do, so its widget is reused.
- Coalescing is not needed in the app: `SessionViewBuilder` rebuilds through `setState`, so several views in
  one frame produce one build.

### Opening a session

Time from a click on a session in the sidebar to the first frame of its transcript, profile build on this Mac
(M-series), sessions against the fake provider: "Small" is 36 items (229 KB file), "Big" 1,836 items with
thinking, `bash` and `read` calls with 16 KB results, markdown with code and tables (7.6 MB file, a recorded session
repeated). Cold: no run holds the session, so the click launches omp. Attach: a run holds it, and the device replays
its `out.jsonl`, which holds one earlier open. SSH: the `harness/sshd` target container.

| | Before | After |
|---|---|---|
| This computer, Small, cold / attach (median of 3) | 376 / 161 ms | 499 / 188 ms |
| This computer, Big, cold / attach (median of 3) | 784 / 911 ms | 572 / 290 ms |
| SSH, Small, cold / attach (before: single runs; after: median of 3) | 2,670 / 1,129 ms | 945 / 250 ms |
| SSH, Big, cold / attach (before: single runs; after: median of 3) | 16,673 / 29,079 ms | 1,488 / 979 ms |

The Small "after" medians are within the spread of both builds (414–699 ms and 373–415 ms cold); the machine ran
other builds meanwhile. Where the time went, and what changed:
- **SSH cipher.** dartssh2's AES-GCM, first in its default list, moves 0.8 MB/s; chacha20-poly1305 13.8 MB/s. The
  link now prefers chacha20-poly1305 (`ssh_link.dart`). The Big history (10.2 MB of `rpc_chunk`s) took 15 s to
  arrive before.
- **History from the session file.** `get_entries` answered with the whole history: omp spent about 400 ms
  producing 10.2 MB, the app 230 ms decoding it on the UI isolate, and every later attach replayed it from
  `out.jsonl` (twice after two opens). The first attach now reads the file `meta.json` names while omp starts,
  parses it on another isolate (90–140 ms for 7.6 MB) and asks omp only for `get_entries(since: <its last
  entry>)`.
- **Replaying `out.jsonl` on macOS.** BSD `tail -F` copies byte by byte, about 15 MB/s; the follower now sends what
  the log holds with a plain `tail` (20 MB in 15 ms) before `tail -F` follows.
- **Frames over 1 MiB decode on another isolate** (`RpcFrameDecoder.pushOffIsolate`); later lines wait, so frame
  order holds. Decoding the 7.6 MB history took 90–110 ms on the UI isolate.
- **`get_available_commands` goes first.** omp answers in order; the companion calls waited 590 ms for the history
  answer queued ahead of it.

What remains for a cold open: launching the run (130–340 ms, `openRun` with its run listing) and omp starting
and loading the session (260–400 ms for these two, then `ready`). The row model for 1,836 items takes 1.4–2.5 ms
and the first frame 10–40 ms.

**Large sessions open with their latest page.** A session file over 16 MB opens with its last 2 MB (about 330 items
here); scrolling up, the transcript reads the 2 MB before it (`LiveSession.loadEarlier`), and so on to the start. A
leaf on an older branch reads back until its page is loaded, and revealing an entry from the tree loads pages until
it arrives. Session files of the user's machine for scale: p50 0.9 MB, p90 3.0 MB, p99 9.6 MB, five over 50 MB, the
largest 414 MB. Synthetic sessions of 24,030 items (100 MB) and 96,012 items (400 MB), two rounds each:

| | Before: whole file | After: last 2 MB |
|---|---|---|
| This computer, 100 MB, cold / attach | 1,485 and 1,425 / 1,167 and 1,145 ms | 734 and 590 / 265 and 164 ms |
| This computer, 400 MB, cold / attach | 6,825 and 6,509 / 5,727 and 5,521 ms | 1,628 and 1,485 / 176 and 184 ms |
| SSH, 100 MB, cold / attach | 6,436 and 6,284 / 5,980 and 5,931 ms | 1,556 and 732 / 297 and 191 ms |
| SSH, 400 MB, cold / attach | 26,352 and 25,877 / 25,052 and 24,981 ms | 3,673 and 1,754 / 202 and 273 ms |
| Peak app memory (RSS), 100 MB / 400 MB, this computer | 748 MB / 2,256 MB | 237 MB / 238 MB |
| Peak app memory (RSS), 100 MB / 400 MB, SSH | 663 MB / 1,890 MB | 241 MB / 244 MB |

The rest of the 400 MB cold open is omp's start: attaching to the same run takes 180 ms.

### Scrollbar

A sliver list not laid out to its end estimates its extent as the average height of the rows it built (the
dozen around the viewport) times the rows it did not. Scrolling from one-line answers into answers with code blocks
changed that average, and with it the extent of every row not built: in the widget test in
`transcript_view_test.dart`, one wheel step changed the scroll range by up to 65 %, and the thumb's length with it.
The transcript's delegates now implement `estimateMaxScrollOffset`: the rows laid out plus, for each row not laid
out, its height at its last layout or an estimate from its kind and text (`row_extents.dart`). A row taller than
its estimate moves the total by its own error only; the same test stays under 1 % per step.

In the app (profile build, wheel steps of 150 px from the bottom to the top, window 1280 × 800):

| | Scroll range change per step, worst | Steps over 1 % | Thumb movement beyond the scroll, worst | Steps over 2 px |
|---|---|---|---|---|
| 1,836 items, before | 21.1 % | 34 of 693 | 30.3 px | 37 |
| 1,836 items, after | 0.1 % | 0 of 688 | 0.3 px | 0 |
| 36 items, before (thumb 117–142 px) | 12.5 % | 3 of 26 | 65.9 px | 3 |
| 36 items, after (thumb 139–142 px) | 1.4 % | 1 of 22 | 5.3 px | 2 |

In a paged session the range covers the loaded history only, so the thumb shrinks each time a page arrives: in the
100 MB session, every 200 wheel steps (about 28,000 px) a 2 MB page loaded and the scroll never stalled.
