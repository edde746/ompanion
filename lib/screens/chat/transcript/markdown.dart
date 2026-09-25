import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';

import '../../../i18n/strings.g.dart';
import '../../external_links.dart';
import 'code_block.dart';
import 'highlighter.dart';
import 'transcript_actions.dart';

/// A CommonMark fenced code block (spec §4.5), replacing gpt_markdown's built-in fence, which knows only ``` and
/// closes at any line starting with ```: an opening run of three or more [char]s indented at most three spaces, an
/// info string (without backticks for a backtick fence), and a closing run of the same character at least as long
/// with nothing after it. The opener's indentation is removed from the content lines. An unclosed fence runs to the
/// end of the text with [MdCustomBlock.closed] false, which is how a streaming block arrives. [MdCustomBlock.data]
/// is the info string.
final class CommonMarkFence extends MarkdownBlockSyntax {
  const CommonMarkFence(this.char);

  static const backtick = CommonMarkFence('`');
  static const tilde = CommonMarkFence('~');

  /// `` ` `` or `~`.
  final String char;

  @override
  String get type => char == '`' ? 'backtick-fence' : 'tilde-fence';

  @override
  String get prefix => char * 3;

  @override
  MarkdownBlockMatch? parse(List<String> lines, int startLine) {
    final opener = lines[startLine];
    final indent = _leadingSpaces(opener);
    if (indent > 3) return null;
    final run = _run(opener, indent);
    if (run < 3) return null;
    final info = opener.substring(indent + run).trim();
    if (char == '`' && info.contains('`')) return null;
    var end = startLine + 1;
    while (end < lines.length && !_closes(lines[end], run)) {
      end++;
    }
    final closed = end < lines.length;
    return MarkdownBlockMatch(
      node: MdCustomBlock(
        type: type,
        body: [for (final line in lines.sublist(startLine + 1, end)) _dedent(line, indent)].join('\n'),
        closed: closed,
        data: info,
      ),
      endLine: closed ? end + 1 : end,
    );
  }

  bool _closes(String line, int openerRun) {
    final indent = _leadingSpaces(line);
    if (indent > 3) return false;
    final run = _run(line, indent);
    return run >= openerRun && line.substring(indent + run).trim().isEmpty;
  }

  int _run(String line, int from) {
    var end = from;
    while (end < line.length && line[end] == char) {
      end++;
    }
    return end - from;
  }

  static int _leadingSpaces(String line) {
    var count = 0;
    while (count < line.length && line.codeUnitAt(count) == 0x20) {
      count++;
    }
    return count;
  }

  static String _dedent(String line, int indent) {
    final spaces = _leadingSpaces(line);
    return line.substring(spaces < indent ? spaces : indent);
  }
}

// gpt_markdown caches its block registry by the identity of this list: it must be created once.
final List<MarkdownBlockComponent> _blockComponents = [
  const MarkdownBlockComponent(syntax: CommonMarkFence.backtick, builder: _fence),
  const MarkdownBlockComponent(syntax: CommonMarkFence.tilde, builder: _fence),
];

Widget _fence(BuildContext context, MdCustomBlock node, GptMarkdownConfig config) {
  final info = node.data as String? ?? '';
  final name = info.split(RegExp(r'\s+')).first;
  return CodeBlock(code: node.body, language: languageForFence(name), label: name, closed: node.closed);
}

/// Built-in fences can still reach the renderer through a construct the fence rule does not own.
Widget _builtInFence(BuildContext context, String name, String code, bool closed) =>
    CodeBlock(code: code, language: languageForFence(name), label: name, closed: closed);

/// An image of the transcript's markdown: an inline `data:` image is drawn, a web image waits for a tap
/// ([_RemoteImage]), and anything else shows its URL. [alt] is the image's alt text, empty when unknown.
Widget _image(BuildContext context, String url, String alt, double? width, double? height) {
  final uri = Uri.tryParse(url);
  final data = uri != null && uri.isScheme('data') ? uri.data : null;
  if (data != null && data.mimeType.startsWith('image/')) {
    return Image.memory(
      data.contentAsBytes(),
      width: width,
      height: height,
      errorBuilder: (context, error, stack) => Text(alt.isEmpty ? context.t.transcript.image : alt),
    );
  }
  if (uri == null || !isWebLink(uri)) return Text(url);
  return _RemoteImage(url: url, host: uri.host, alt: alt, width: width, height: height);
}

/// A web image of model output, fetched only once the user taps it. Loading it on its own would send whatever its
/// URL carries, such as file contents a prompt injection put there, to that server from every device showing the
/// session.
class _RemoteImage extends StatefulWidget {
  const _RemoteImage({required this.url, required this.host, required this.alt, this.width, this.height});

  final String url;
  final String host;
  final String alt;
  final double? width;
  final double? height;

  @override
  State<_RemoteImage> createState() => _RemoteImageState();
}

class _RemoteImageState extends State<_RemoteImage> {
  var _load = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    if (_load) {
      return Image.network(
        widget.url,
        width: widget.width,
        height: widget.height,
        errorBuilder: (context, error, stack) => Text(widget.url, style: TextStyle(color: scheme.error)),
      );
    }
    final t = context.t.transcript;
    return Tooltip(
      message: widget.url,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: const BorderRadius.all(Radius.circular(8)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.image_outlined, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Flexible(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.alt.isEmpty ? t.image : widget.alt, maxLines: 2, overflow: TextOverflow.ellipsis),
                  Text(widget.host, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(onPressed: () => setState(() => _load = true), child: Text(t.loadImage)),
          ],
        ),
      ),
    );
  }
}

/// Alt text by URL of the images in [markdown]: the builder gpt_markdown calls for an image gets only its URL, the
/// whole text between the parentheses, trimmed. Brackets and parentheses nest and a backslash escapes, as in
/// gpt_markdown's own image rule; the first image with a URL gives its alt text.
Map<String, String> markdownImageAlts(String markdown) {
  final alts = <String, String>{};
  for (var start = markdown.indexOf('!['); start >= 0; start = markdown.indexOf('![', start + 2)) {
    final altEnd = _closing(markdown, start + 1, '[', ']');
    if (altEnd < 0 || altEnd + 1 >= markdown.length || markdown[altEnd + 1] != '(') continue;
    final urlEnd = _closing(markdown, altEnd + 1, '(', ')');
    if (urlEnd < 0) continue;
    alts.putIfAbsent(markdown.substring(altEnd + 2, urlEnd).trim(), () => markdown.substring(start + 2, altEnd));
  }
  return alts;
}

/// Index of the [close] matching the [open] at [from], or -1.
int _closing(String text, int from, String open, String close) {
  var depth = 0;
  for (var i = from; i < text.length; i++) {
    final char = text[i];
    if (char == r'\') {
      i++;
    } else if (char == open) {
      depth++;
    } else if (char == close && --depth == 0) {
      return i;
    }
  }
  return -1;
}

final _fenceLine = RegExp(r'^ {0,3}(`{3,}|~{3,})(.*)$');

/// Rewrites `$…$` and `$$…$$` math into the `\(…\)` and `\[…\]` forms gpt_markdown always renders, outside fenced
/// code and inline code spans. gpt_markdown's own `$` support rewrites inside inline code too (`` `$HOME` `` breaks);
/// here an inline `$` follows Pandoc's rule instead: the opening `$` has a non-space right after it, the closing `$`
/// a non-space right before it and no digit after it, both on one line, so prices like "$5 and $10" stay text.
String rewriteDollarMath(String source) {
  if (!source.contains(r'$')) return source;
  final out = StringBuffer();
  final lines = source.split('\n');
  final chunk = <String>[];
  String? fence;
  var fenceRun = 0;

  void flushChunk() {
    if (chunk.isEmpty) return;
    out.write(_rewriteInline(chunk.join('\n')));
    chunk.clear();
  }

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final newline = i < lines.length - 1 ? '\n' : '';
    if (fence != null) {
      out.write('$line$newline');
      final trimmed = line.trimLeft();
      if (line.length - trimmed.length <= 3 && trimmed.startsWith(fence * fenceRun) && trimmed.replaceAll(fence, '').trim().isEmpty) {
        fence = null;
      }
      continue;
    }
    final opener = _fenceLine.firstMatch(line);
    if (opener != null && !(opener[1]![0] == '`' && opener[2]!.contains('`'))) {
      chunk.add('');
      flushChunk();
      fence = opener[1]![0];
      fenceRun = opener[1]!.length;
      out.write('$line$newline');
      continue;
    }
    chunk.add(line);
  }
  if (chunk.isNotEmpty) out.write(_rewriteInline(chunk.join('\n')));
  return out.toString();
}

bool _isSpace(int unit) => unit == 0x20 || unit == 0x09 || unit == 0x0a;

bool _isDigit(int unit) => unit >= 0x30 && unit <= 0x39;

String _rewriteInline(String text) {
  if (!text.contains(r'$')) return text;
  final out = StringBuffer();
  final n = text.length;
  var i = 0;
  while (i < n) {
    final unit = text.codeUnitAt(i);
    if (unit == 0x5c && i + 1 < n) {
      // An escaped character, `\$` included, stays as written.
      out.write(text.substring(i, i + 2));
      i += 2;
      continue;
    }
    if (unit == 0x60) {
      // A code span: a backtick run up to the next run of the same length.
      var run = i;
      while (run < n && text.codeUnitAt(run) == 0x60) {
        run++;
      }
      final ticks = text.substring(i, run);
      var close = text.indexOf(ticks, run);
      while (close != -1 && close + ticks.length < n && text.codeUnitAt(close + ticks.length) == 0x60) {
        var skip = close;
        while (skip < n && text.codeUnitAt(skip) == 0x60) {
          skip++;
        }
        close = text.indexOf(ticks, skip);
      }
      final end = close == -1 ? run : close + ticks.length;
      out.write(text.substring(i, end));
      i = end;
      continue;
    }
    if (unit != 0x24) {
      out.writeCharCode(unit);
      i++;
      continue;
    }
    if (i + 1 < n && text.codeUnitAt(i + 1) == 0x24) {
      final close = _unescapedIndexOf(text, r'$$', i + 2);
      if (close != -1 && text.substring(i + 2, close).trim().isNotEmpty) {
        out.write('\\[${text.substring(i + 2, close)}\\]');
        i = close + 2;
      } else {
        out.write(r'$$');
        i += 2;
      }
      continue;
    }
    final close = _inlineMathClose(text, i);
    if (close == -1) {
      out.write(r'$');
      i++;
      continue;
    }
    out.write('\\(${text.substring(i + 1, close)}\\)');
    i = close + 1;
  }
  return out.toString();
}

int _unescapedIndexOf(String text, String pattern, int from) {
  var at = text.indexOf(pattern, from);
  while (at > 0 && text.codeUnitAt(at - 1) == 0x5c) {
    at = text.indexOf(pattern, at + 1);
  }
  return at;
}

/// The index of the `$` closing the inline math opened at [open], or -1.
int _inlineMathClose(String text, int open) {
  final n = text.length;
  if (open + 1 >= n || _isSpace(text.codeUnitAt(open + 1))) return -1;
  for (var j = open + 1; j < n; j++) {
    final unit = text.codeUnitAt(j);
    if (unit == 0x0a) return -1;
    if (unit == 0x5c) {
      j++;
      continue;
    }
    if (unit != 0x24 || j == open + 1) continue;
    if (_isSpace(text.codeUnitAt(j - 1))) continue;
    if (j + 1 < n && _isDigit(text.codeUnitAt(j + 1))) continue;
    return j;
  }
  return -1;
}

final _fileLink = RegExp(r'^(?:file://)?(.+?)(?:#L(\d+)(?:-L?\d+)?|:(\d+)(?::\d+)?)?$');

/// Opens a link from the transcript. A path (no scheme, `file:`, or `name.ext:12`, which parses as a scheme) opens
/// as a file of the session's machine, with a `#L12` or `:12` suffix as the line; anything else goes to
/// [openExternalLink].
Future<void> openTranscriptLink(BuildContext context, String url) async {
  final target = url.trim();
  final uri = Uri.tryParse(target);
  final scheme = uri?.scheme ?? '';
  if (uri == null || scheme.isEmpty || scheme == 'file' || scheme.contains('.') || scheme.length == 1) {
    final match = _fileLink.firstMatch(_decoded(target));
    if (match == null) return;
    TranscriptScope.of(context).onOpenFile(match[1]!, line: int.tryParse(match[2] ?? match[3] ?? ''));
    return;
  }
  await openExternalLink(context, uri);
}

/// [target] percent-decoded, or as written when it is not valid percent-encoding (`100%.md`).
String _decoded(String target) {
  try {
    return Uri.decodeFull(target);
  } on ArgumentError {
    return target;
  }
}

/// Markdown text of the transcript: gpt_markdown with the CommonMark fence rule, highlighted code blocks, LaTeX and
/// links. gpt_markdown splits the text into segments, keeps the settled ones and parses only the changed tail, so a
/// streaming message costs its growing tail per update; that cache lives in this widget's element.
class TranscriptMarkdown extends StatefulWidget {
  const TranscriptMarkdown(this.text, {super.key, this.style});

  final String text;
  final TextStyle? style;

  @override
  State<TranscriptMarkdown> createState() => _TranscriptMarkdownState();
}

class _TranscriptMarkdownState extends State<TranscriptMarkdown> {
  String? _source;
  String _prepared = '';
  Map<String, String> _alts = const {};

  // gpt_markdown keeps the spans of settled segments, taps included, across builds: the handler resolves the link
  // through this state's context when tapped rather than capturing anything from one build.
  void _onLinkTap(String url, String title) => openTranscriptLink(context, url);

  Widget _buildImage(BuildContext context, String url, double? width, double? height) =>
      _image(context, url, _alts[url] ?? '', width, height);

  @override
  Widget build(BuildContext context) {
    if (!identical(widget.text, _source)) {
      _source = widget.text;
      _prepared = rewriteDollarMath(widget.text);
      _alts = markdownImageAlts(_prepared);
    }
    final theme = Theme.of(context);
    return GptMarkdown(
      _prepared,
      style: widget.style ?? theme.textTheme.bodyMedium,
      blockComponents: _blockComponents,
      codeBuilder: _builtInFence,
      imageBuilder: _buildImage,
      onLinkTap: _onLinkTap,
      styleSheet: _styleSheet(theme.colorScheme),
    );
  }
}

final _styleSheets = Expando<GptMarkdownStyleSheet>();

GptMarkdownStyleSheet _styleSheet(ColorScheme scheme) => _styleSheets[scheme] ??= GptMarkdownStyleSheet(
  table: TableStyle(
    borderColor: scheme.outlineVariant,
    borderRadius: const Radius.circular(6),
    headerBackground: scheme.surfaceContainerHigh,
  ),
);
