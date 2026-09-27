import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph, RenderTable;
import 'package:gpt_markdown/custom_widgets/unordered_ordered_list.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
// gpt_markdown's own line tests, so blocks are cut where its parser starts them.
import 'package:gpt_markdown/plusparse/scanner.dart'
    show checkboxMarker, indentWidth, isBlank, isHeading, isHr, orderedMarker, radioMarker, unorderedMarker;

import '../../../app/theme.dart';
import '../../../i18n/strings.g.dart';
import '../../external_links.dart';
import 'code_block.dart';
import 'highlighter.dart';
import 'images.dart';
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

/// The rows of a pipe table: [aligns] has one entry per column, [rows] starts with the header row and every row has
/// one cell per column.
final class MarkdownTable {
  const MarkdownTable(this.aligns, this.rows);

  final List<TextAlign> aligns;
  final List<List<String>> rows;
}

/// A GFM pipe table (spec §4.10) whose rows start with `|`: a header row, a delimiter row with as many cells, and the
/// body rows up to the first line that does not start with `|`. It replaces gpt_markdown's table, which sizes itself to
/// its content inside a scroll view that hides the available width, so it cannot fill the transcript. [MdCustomBlock.data]
/// is the [MarkdownTable]; a table whose rows omit the leading pipe still reaches gpt_markdown's renderer.
final class PipeTable extends MarkdownBlockSyntax {
  const PipeTable();

  @override
  String get type => 'pipe-table';

  @override
  String get prefix => '|';

  @override
  MarkdownBlockMatch? parse(List<String> lines, int startLine) {
    if (startLine + 1 >= lines.length || CommonMarkFence._leadingSpaces(lines[startLine]) > 3) return null;
    final header = tableCells(lines[startLine]);
    final delimiter = tableCells(lines[startLine + 1]);
    if (delimiter.length != header.length || !delimiter.every(_delimiterCell.hasMatch)) return null;
    var end = startLine + 2;
    while (end < lines.length && lines[end].trimLeft().startsWith('|')) {
      end++;
    }
    final aligns = [
      for (final cell in delimiter)
        cell.endsWith(':') ? (cell.startsWith(':') ? TextAlign.center : TextAlign.right) : TextAlign.left,
    ];
    final rows = [
      header,
      for (final line in lines.sublist(startLine + 2, end))
        [
          for (final (index, cell) in tableCells(line).take(header.length).indexed)
            if (index < header.length) cell,
        ],
    ];
    for (final row in rows) {
      while (row.length < header.length) {
        row.add('');
      }
    }
    return MarkdownBlockMatch(
      node: MdCustomBlock(
        type: type,
        body: lines.sublist(startLine, end).join('\n'),
        data: MarkdownTable(aligns, rows),
      ),
      endLine: end,
    );
  }
}

final _delimiterCell = RegExp(r'^:?-+:?$');

/// The trimmed cells of a table row: an outer pipe on either side is dropped and `\|` is a pipe inside a cell.
List<String> tableCells(String line) {
  var text = line.trim();
  if (text.startsWith('|')) text = text.substring(1);
  if (text.endsWith('|') && !text.endsWith(r'\|')) text = text.substring(0, text.length - 1);
  final cells = <String>[];
  final cell = StringBuffer();
  for (var i = 0; i < text.length; i++) {
    final char = text[i];
    if (char == r'\' && i + 1 < text.length && text[i + 1] == '|') {
      cell.write('|');
      i++;
    } else if (char == '|') {
      cells.add(cell.toString().trim());
      cell.clear();
    } else {
      cell.write(char);
    }
  }
  cells.add(cell.toString().trim());
  return cells;
}

/// A GFM task list (spec §5.3): consecutive `- [ ] item` / `- [x] item` lines with the same bullet [marker], each
/// with its indented continuation lines. gpt_markdown draws a task item as a bullet followed by a padded Material
/// checkbox; this draws the box in place of the bullet at list spacing. [MdCustomBlock.data] is a list of
/// `(checked, text)` records.
final class TaskList extends MarkdownBlockSyntax {
  const TaskList(this.marker);

  static const dash = TaskList('-');
  static const star = TaskList('*');
  static const plus = TaskList('+');

  /// `-`, `*` or `+`.
  final String marker;

  @override
  String get type => switch (marker) {
    '-' => 'task-list-dash',
    '*' => 'task-list-star',
    _ => 'task-list-plus',
  };

  @override
  String get prefix => '$marker [';

  @override
  MarkdownBlockMatch? parse(List<String> lines, int startLine) {
    final items = <(bool, String)>[];
    var end = startLine;
    while (end < lines.length) {
      final line = lines[end];
      final item = _taskItem.firstMatch(line);
      if (item != null && item[1] == marker) {
        items.add((item[2] != ' ', item[3] ?? ''));
      } else if (items.isNotEmpty && line.startsWith('  ') && line.trim().isNotEmpty && !_listItem.hasMatch(line)) {
        final (checked, text) = items.removeLast();
        items.add((checked, '$text ${line.trim()}'));
      } else {
        break;
      }
      end++;
    }
    if (items.isEmpty) return null;
    return MarkdownBlockMatch(
      node: MdCustomBlock(type: type, body: lines.sublist(startLine, end).join('\n'), data: items),
      endLine: end,
    );
  }
}

final _taskItem = RegExp(r'^ {0,3}([-*+]) \[([ xX])\](?: (.*))?$');
final _listItem = RegExp(r'^\s*(?:[-*+]|\d{1,9}[.)])(?:\s|$)');

// gpt_markdown caches its block registry by the identity of this list: it must be created once.
final List<MarkdownBlockComponent> _blockComponents = [
  const MarkdownBlockComponent(syntax: CommonMarkFence.backtick, builder: _fence),
  const MarkdownBlockComponent(syntax: CommonMarkFence.tilde, builder: _fence),
  const MarkdownBlockComponent(syntax: PipeTable(), builder: _table),
  const MarkdownBlockComponent(syntax: TaskList.dash, builder: _tasks),
  const MarkdownBlockComponent(syntax: TaskList.star, builder: _tasks),
  const MarkdownBlockComponent(syntax: TaskList.plus, builder: _tasks),
];

final _blockRegistry = MarkdownBlockRegistry([for (final component in _blockComponents) component.syntax]);

Widget _fence(BuildContext context, MdCustomBlock node, GptMarkdownConfig config) {
  final info = node.data as String? ?? '';
  final name = info.split(RegExp(r'\s+')).first;
  return CodeBlock(code: node.body, language: languageForFence(name), closed: node.closed);
}

/// Built-in fences can still reach the renderer through a construct the fence rule does not own.
Widget _builtInFence(BuildContext context, String name, String code, bool closed) =>
    CodeBlock(code: code, language: languageForFence(name), closed: closed);

/// Inline markdown [text] rendered as gpt_markdown renders a table cell.
Widget _inline(BuildContext context, String text, GptMarkdownConfig config) => config.getRich(
  TextSpan(children: PlusparseRenderer.render(context, text, config, inlineOnly: true)),
  ambientScaling: config.blocksRenderDirectly,
);

Widget _table(BuildContext context, MdCustomBlock node, GptMarkdownConfig config) =>
    _TableView(table: node.data! as MarkdownTable, config: config);

/// A pipe table at the full available width: every column its content's width when they all fit, the last one taking
/// what is left; else the widest columns wrap at one shared width so the table still fits, and a table that cannot
/// fit even so scrolls sideways. A muted header over rows that alternate two surface tones separates the cells.
class _TableView extends StatefulWidget {
  const _TableView({required this.table, required this.config});

  final MarkdownTable table;
  final GptMarkdownConfig config;

  @override
  State<_TableView> createState() => _TableViewState();
}

class _TableViewState extends State<_TableView> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final table = widget.table;
    final config = widget.config;
    // Cells one step under the body text: a table is data, read across. Code in a cell is told by its font alone: a
    // chip's tone on the striped rows would box it a second time, lighter on one row than on the next.
    final cellStyle = (config.style ?? const TextStyle()).copyWith(
      fontSize: (Theme.of(context).textTheme.bodyMedium?.fontSize ?? 14) - 1,
    );
    const cellCode = InlineCodeStyle(backgroundColor: Color(0x00000000), borderWidth: 0);
    final bodyConfig = config.copyWith(style: cellStyle, inlineCodeStyle: cellCode);
    final headerConfig = config.copyWith(
      style: cellStyle.copyWith(fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
      inlineCodeStyle: cellCode.copyWith(color: scheme.onSurfaceVariant),
    );
    Widget cell(GptMarkdownConfig base, int column, String text) => Padding(
      padding: _cellPadding,
      child: _inline(
        context,
        text,
        table.aligns[column] == TextAlign.left ? base : base.copyWith(textAlign: table.aligns[column]),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite ? constraints.maxWidth : 0.0;
        final plan = _TablePlan(width);
        final columns = table.aligns.length;
        final grid = Table(
          columnWidths: {
            for (var column = 0; column < columns; column++)
              column: _PlannedColumn(plan, column, last: column == columns - 1),
          },
          children: [
            for (final (index, row) in table.rows.indexed)
              TableRow(
                decoration: BoxDecoration(color: index.isOdd ? scheme.surfaceContainerLow : scheme.surfaceContainer),
                children: [
                  for (final (column, text) in row.indexed) cell(index == 0 ? headerConfig : bodyConfig, column, text),
                ],
              ),
          ],
        );
        return ClipRRect(
          borderRadius: BorderRadius.circular(AppSizes.radius),
          child: Scrollbar(
            controller: _scroll,
            child: SideScrollView(
              controller: _scroll,
              child: ConstrainedBox(
                constraints: BoxConstraints(minWidth: width),
                child: grid,
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Narrowest a column wraps to before its table scrolls sideways instead.
const _minColumn = 120.0;

const _cellPadding = EdgeInsets.symmetric(horizontal: 12, vertical: 8);

/// The column widths of a table [width] wide, measured for all its columns at once: a column's width depends on the
/// others'. Each cell is laid out unconstrained, as gpt_markdown sizes its columns.
final class _TablePlan {
  _TablePlan(this.width);

  final double width;
  List<double> _widths = const [];

  void measure(RenderTable table) {
    final contents = <double>[];
    final codes = <double>[];
    for (var x = 0; x < table.columns; x++) {
      var content = 0.0;
      var code = 0.0;
      for (final cell in table.column(x)) {
        cell.layout(const BoxConstraints(), parentUsesSize: true);
        content = math.max(content, cell.size.width);
        code = math.max(code, _widestCode(cell));
      }
      contents.add(content);
      codes.add(code);
    }
    _widths = _fitColumns(contents, codes, width);
  }
}

/// Width of the widest inline code span in [cell], which was just laid out unconstrained, with the cell padding.
double _widestCode(RenderBox cell) {
  RenderParagraph? found;
  void find(RenderObject child) {
    if (child is RenderParagraph) {
      found ??= child;
    } else {
      child.visitChildren(find);
    }
  }

  find(cell);
  final paragraph = found;
  if (paragraph == null) return 0;
  var widest = 0.0;
  var offset = 0;
  paragraph.text.visitChildren((span) {
    final length = span is TextSpan ? span.text?.length ?? 0 : 1;
    if (span is CodeTextSpan) {
      // Laid out unconstrained, the span is on one line: its boxes add up to its width.
      final boxes = paragraph.getBoxesForSelection(TextSelection(baseOffset: offset, extentOffset: offset + length));
      widest = math.max(widest, boxes.fold(0.0, (width, box) => width + box.right - box.left));
    }
    offset += length;
    return true;
  });
  return widest == 0 ? 0 : widest + _cellPadding.horizontal;
}

/// Widths for columns whose content is [contents] wide in a table [width] wide: the contents when they fit. Else the
/// wide columns wrap at one shared width, but none under [_minColumn] or its widest code span ([codes]: a path or a
/// name broken at a hyphen reads as two), and the narrow ones keep theirs. A table whose columns do not fit even so
/// gets those floors and scrolls sideways.
List<double> _fitColumns(List<double> contents, List<double> codes, double width) {
  double sum(Iterable<double> widths) => widths.fold(0.0, (sum, width) => sum + width);
  if (sum(contents) <= width) return contents;
  final floors = [for (final (x, content) in contents.indexed) math.min(content, math.max(codes[x], _minColumn))];
  if (sum(floors) >= width) return floors;
  List<double> capped(double cap) => [for (final (x, content) in contents.indexed) cap.clamp(floors[x], content)];
  // The shared width that fills the table, to well under a pixel.
  var low = 0.0;
  var high = contents.reduce(math.max);
  for (var step = 0; step < 32; step++) {
    final cap = (low + high) / 2;
    if (sum(capped(cap)) > width) {
      high = cap;
    } else {
      low = cap;
    }
  }
  return capped(low);
}

/// Column [index] of a [_TablePlan]; the [last] column also takes what the table has left over. A table asks each
/// column for its maximum width before its minimum, first to last, so the first column's question measures them all.
final class _PlannedColumn extends TableColumnWidth {
  const _PlannedColumn(this.plan, this.index, {required this.last});

  final _TablePlan plan;
  final int index;
  final bool last;

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    if (cells.isEmpty) return 0;
    if (index == 0 || plan._widths.isEmpty) plan.measure(cells.first.parent! as RenderTable);
    return plan._widths[index];
  }

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) => cells.isEmpty ? 0 : plan._widths[index];

  @override
  double? flex(Iterable<RenderBox> cells) => last ? 1 : null;
}

Widget _tasks(BuildContext context, MdCustomBlock node, GptMarkdownConfig config) {
  final style = config.style ?? DefaultTextStyle.of(context).style;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    spacing: _itemGap,
    children: [
      for (final (checked, text) in node.data! as List<(bool, String)>)
        _task(context, style, checked, _inline(context, text, config)),
    ],
  );
}

Widget _checkbox(BuildContext context, bool checked, Widget content, CheckboxStyle style) =>
    _task(context, DefaultTextStyle.of(context).style, checked, content);

/// One task item: a box where a list item has its bullet, centred on the label's first line.
Widget _task(BuildContext context, TextStyle style, bool checked, Widget label) {
  final scheme = Theme.of(context).colorScheme;
  final line = MediaQuery.textScalerOf(context).scale(style.fontSize ?? 14) * (style.height ?? 1.4);
  return Padding(
    padding: const EdgeInsets.only(left: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.only(top: math.max(0, (line - 16) / 2)),
          child: Icon(
            checked ? Icons.check_box : Icons.check_box_outline_blank,
            size: 16,
            color: checked ? scheme.onSurface : scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(child: label),
      ],
    ),
  );
}

/// A bullet list item as gpt_markdown draws it by default, set off like any nested item ([_nested]).
Widget _bullet(BuildContext context, Widget child, GptMarkdownConfig config) {
  final style = config.style ?? DefaultTextStyle.of(context).style;
  return _nested(
    config,
    UnorderedListView(
      scalesItsOwnText: config.blocksRenderDirectly,
      bulletColor: style.color,
      padding: 7,
      spacing: 10,
      bulletSize: 0.3 * (style.fontSize ?? kDefaultFontSize),
      textDirection: config.textDirection,
      child: child,
    ),
  );
}

/// A numbered list item as gpt_markdown draws it by default, set off like any nested item ([_nested]).
Widget _numbered(BuildContext context, String no, Widget child, GptMarkdownConfig config) => _nested(
  config,
  OrderedListView(
    scalesItsOwnText: config.blocksRenderDirectly,
    no: '$no.',
    textDirection: config.textDirection,
    style: (config.style ?? const TextStyle()).copyWith(fontWeight: FontWeight.w100),
    padding: 6,
    spacing: 6,
    child: child,
  ),
);

/// A nested list item sits on its own line of its parent item's paragraph, which has no gap between lines: its own
/// padding tucks the list under the parent's line and spaces the items. A top-level item is a block of its own,
/// spaced by [TranscriptMarkdown].
Widget _nested(GptMarkdownConfig config, Widget item) => config.blocksRenderDirectly
    ? item
    : Padding(
        padding: const EdgeInsets.only(top: _nestedAbove, bottom: _itemGap - _nestedAbove),
        child: item,
      );

/// A quote as a flat block of dimmed text.
Widget _quote(BuildContext context, Widget content, BlockQuoteStyle style) => Container(
  width: double.infinity,
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  decoration: BoxDecoration(
    color: Theme.of(context).colorScheme.surfaceContainer,
    borderRadius: BorderRadius.circular(AppSizes.radius),
  ),
  child: content,
);

/// A thematic break is a gap, not a rule.
Widget _rule(BuildContext context, HrStyle style) => const SizedBox(height: 8);

/// An image of the transcript's markdown: an inline `data:` image is drawn, a path names a file of the session's
/// machine and loads from there ([MachineImage]), a web image waits for a tap ([_RemoteImage]), and anything else
/// shows its URL. [alt] is the image's alt text, empty when unknown.
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
  if (machineImagePath(url) case final path?) return MachineImage(path: path);
  if (uri == null || !isWebLink(uri)) return Text(url);
  return _RemoteImage(url: url, host: uri.host, alt: alt, width: width, height: height);
}

final _windowsPath = RegExp(r'^(?:[A-Za-z]:[\\/]|\\\\)');

/// The machine path a markdown image names: an absolute POSIX or Windows path, `~/…`, a path relative to the session's
/// directory, or a `file:` URL (its host ignored). Null for `data:`, web and any other URL. Percent-escapes are
/// decoded, since a markdown image URL cannot hold a space.
String? machineImagePath(String src) {
  final target = src.trim();
  if (target.isEmpty) return null;
  if (_windowsPath.hasMatch(target)) return _decoded(target);
  final uri = Uri.tryParse(target);
  if (uri == null) return _decoded(target);
  if (uri.isScheme('file')) {
    final path = _decoded(uri.path);
    // `file:///C:/x` names the Windows path `C:/x`.
    return RegExp(r'^/[A-Za-z]:/').hasMatch(path) ? path.substring(1) : path;
  }
  return uri.scheme.isEmpty ? _decoded(target) : null;
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
        errorBuilder: (context, error, stack) => Text(widget.url, style: TextStyle(color: AppColors.of(context).error)),
      );
    }
    final t = context.t.transcript;
    return Tooltip(
      message: widget.url,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 4, 4, 4),
        decoration: BoxDecoration(color: scheme.surfaceContainer, borderRadius: BorderRadius.circular(AppSizes.radius)),
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
      if (line.length - trimmed.length <= 3 &&
          trimmed.startsWith(fence * fenceRun) &&
          trimmed.replaceAll(fence, '').trim().isEmpty) {
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

/// The transcript's vertical rhythm (docs/design.md, "Markdown"): GitHub's markdown spacing scaled to the 14 px body.
/// Logical pixels at a text scale of 1.
const markdownLineHeight = 1.5;
const _blockGap = 12.0;
const _itemGap = 6.0;
const _headingAbove = 20.0;
const _headingBelow = 8.0;
const _nestedAbove = 4.0;

/// A top-level block of markdown: its source, whether it is a heading, and for a list item the list it belongs to
/// (its marker kind and indentation).
typedef _Block = ({String text, bool heading, String? list});

/// [source] cut into its top-level blocks where gpt_markdown's block parser starts one, each list item a block of its
/// own. gpt_markdown stacks the blocks of one blank-line segment with no space between them, and blank-line segments
/// 1.15 lines apart, so the rhythm is laid out here from these blocks instead.
List<_Block> _markdownBlocks(String source) {
  final blocks = <_Block>[];
  for (final segment in splitStreamSegments(source, blockRegistry: _blockRegistry)) {
    final lines = segment.split('\n');
    var i = 0;
    while (i < lines.length) {
      final start = i;
      final trimmed = lines[i].trimLeft();
      var heading = false;
      String? list;
      final custom = _blockRegistry.match(lines, i);
      if (custom != null) {
        i = custom.endLine;
      } else if (trimmed.startsWith('```')) {
        // A fence the CommonMark rule rejects still runs to the next ``` line in gpt_markdown's parser.
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          i++;
        }
        i = math.min(i + 1, lines.length);
      } else if (trimmed.startsWith(r'\[')) {
        i = _mathEnd(lines, i);
      } else if (isHeading(trimmed) != null) {
        heading = true;
        i++;
      } else if (isHr(trimmed) || checkboxMarker(trimmed) != null || radioMarker(trimmed) != null) {
        i++;
      } else if (trimmed.startsWith('>')) {
        // A quote runs to the next blank line, lazy continuation lines included.
        while (i < lines.length && !isBlank(lines[i])) {
          i++;
        }
      } else if (unorderedMarker(trimmed) != null || orderedMarker(trimmed) != null) {
        final indent = indentWidth(lines[i]);
        list = '${orderedMarker(trimmed) == null ? '-' : '1'}$indent';
        // The item's own lines are indented past its marker.
        i++;
        while (i < lines.length && (isBlank(lines[i]) || indentWidth(lines[i]) > indent)) {
          i++;
        }
      } else {
        i++;
        while (i < lines.length &&
            !isBlank(lines[i]) &&
            !_startsBlock(lines[i].trimLeft()) &&
            _blockRegistry.match(lines, i) == null) {
          i++;
        }
      }
      blocks.add((text: lines.sublist(start, i).join('\n'), heading: heading, list: list));
    }
  }
  return blocks;
}

/// Whether a line inside a segment ends a paragraph, as in gpt_markdown's block parser.
bool _startsBlock(String trimmed) =>
    trimmed.startsWith('```') ||
    trimmed.startsWith(r'\[') ||
    isHeading(trimmed) != null ||
    isHr(trimmed) ||
    trimmed.startsWith('>') ||
    checkboxMarker(trimmed) != null ||
    radioMarker(trimmed) != null ||
    unorderedMarker(trimmed) != null ||
    orderedMarker(trimmed) != null;

/// The line after the block maths opened at [start], or the end while its `\]` has not arrived.
int _mathEnd(List<String> lines, int start) {
  var first = lines[start].trimLeft();
  while (first.startsWith(r'\[')) {
    first = first.substring(2);
  }
  if (first.contains(r'\]')) return start + 1;
  var i = start + 1;
  while (i < lines.length && !lines[i].contains(r'\]')) {
    i++;
  }
  return math.min(i + 1, lines.length);
}

/// The space between two blocks: headings stand apart from what comes before them and hold on to what follows, items
/// of one list stay close, and every other block keeps the block gap.
double _gap(_Block above, _Block below) => below.heading
    ? _headingAbove
    : above.heading
    ? _headingBelow
    : above.list != null && above.list == below.list
    ? _itemGap
    : _blockGap;

/// Markdown text of the transcript: gpt_markdown with the CommonMark fence rule, highlighted code blocks, LaTeX and
/// links, in the transcript's vertical rhythm: one gpt_markdown per top-level block, spaced by [_gap]. A streaming
/// message only grows its last block, and every block before it keeps its widget, so Flutter skips them.
class TranscriptMarkdown extends StatefulWidget {
  const TranscriptMarkdown(this.text, {super.key, this.style, this.previous});

  final String text;
  final TextStyle? style;

  /// The markdown this text continues, when a long text is cut into parts (`textParts` cuts between segments): the
  /// first block keeps the gap it has below the last block of [previous] in one piece, so a cut that moves while the
  /// text streams moves nothing.
  final String? previous;

  @override
  State<TranscriptMarkdown> createState() => _TranscriptMarkdownState();
}

class _TranscriptMarkdownState extends State<TranscriptMarkdown> {
  String? _source;
  List<_Block> _blocks = const [];
  Map<String, String> _alts = const {};
  String? _previous;
  _Block? _previousBlock;

  /// Each block's widget by its source, for the [_style] and [_theme] they were built with.
  var _widgets = <String, Widget>{};
  TextStyle? _style;
  ThemeData? _theme;

  // gpt_markdown keeps the spans of settled segments, taps included, across builds: the handler resolves the link
  // through this state's context when tapped rather than capturing anything from one build.
  void _onLinkTap(String url, String title) => openTranscriptLink(context, url);

  Widget _buildImage(BuildContext context, String url, double? width, double? height) =>
      _image(context, url, _alts[url] ?? '', width, height);

  Widget _block(String text, TextStyle style, ThemeData theme) => GptMarkdown(
    text,
    style: style,
    blockComponents: _blockComponents,
    codeBuilder: _builtInFence,
    imageBuilder: _buildImage,
    checkboxBuilder: _checkbox,
    orderedListBuilder: _numbered,
    unOrderedListBuilder: _bullet,
    blockQuoteBuilder: _quote,
    hrBuilder: _rule,
    onLinkTap: _onLinkTap,
    styleSheet: _styleSheet(theme.colorScheme),
  );

  @override
  Widget build(BuildContext context) {
    if (!identical(widget.text, _source)) {
      _source = widget.text;
      final prepared = rewriteDollarMath(widget.text);
      _alts = markdownImageAlts(prepared);
      _blocks = _markdownBlocks(prepared);
    }
    final previous = widget.previous;
    if (!identical(previous, _previous)) {
      _previous = previous;
      _previousBlock = previous == null ? null : _markdownBlocks(rewriteDollarMath(previous)).last;
    }
    final theme = Theme.of(context);
    final style = (widget.style ?? theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
      height: markdownLineHeight,
    );
    if (style != _style || !identical(theme, _theme)) {
      _widgets = {};
      _style = style;
      _theme = theme;
    }
    final built = _widgets;
    final widgets = <String, Widget>{};
    final scaler = MediaQuery.textScalerOf(context);
    final children = [
      for (final (index, block) in _blocks.indexed)
        Padding(
          padding: EdgeInsets.only(
            top: switch (index == 0 ? _previousBlock : _blocks[index - 1]) {
              null => 0,
              final above => scaler.scale(_gap(above, block)),
            },
          ),
          child: widgets[block.text] ??= built[block.text] ?? _block(block.text, style, theme),
        ),
    ];
    _widgets = widgets;
    return GptMarkdownTheme(
      gptThemeData: _markdownTheme(theme),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: children),
    );
  }
}

final _markdownThemes = Expando<GptMarkdownThemeData>();

/// Headings one step above the body text each, without the rule gpt_markdown draws under a first-level heading.
GptMarkdownThemeData _markdownTheme(ThemeData theme) => _markdownThemes[theme] ??= () {
  final body = theme.textTheme.bodyMedium?.fontSize ?? 14;
  TextStyle heading(double size) => TextStyle(fontSize: size, fontWeight: FontWeight.w600, height: 1.3);
  return GptMarkdownThemeData(
    brightness: theme.brightness,
    h1: heading(body + 6),
    h2: heading(body + 3),
    h3: heading(body + 1),
    h4: heading(body),
    h5: heading(body),
    h6: heading(body),
    autoAddDividerLineAfterH1: false,
    linkColor: theme.colorScheme.onSurface,
    linkHoverColor: theme.colorScheme.onSurfaceVariant,
  );
}();

final _styleSheets = Expando<GptMarkdownStyleSheet>();

GptMarkdownStyleSheet _styleSheet(ColorScheme scheme) => _styleSheets[scheme] ??= GptMarkdownStyleSheet(
  heading: const HeadingStyle(showDivider: false),
  link: LinkStyle(color: scheme.onSurface, hoverColor: scheme.onSurfaceVariant, decoration: TextDecoration.underline),
  inlineCode: InlineCodeStyle(backgroundColor: scheme.surfaceContainerHigh, borderWidth: 0),
  blockQuote: BlockQuoteStyle(textStyle: TextStyle(color: scheme.onSurfaceVariant)),
  // Tables without a leading pipe still use gpt_markdown's table: flat, like [PipeTable]'s.
  table: TableStyle(
    borderColor: const Color(0x00000000),
    borderWidth: 0,
    borderRadius: const Radius.circular(AppSizes.radius),
    headerBackground: scheme.surfaceContainerHigh,
    rowStripeColor: scheme.surfaceContainer,
  ),
);
