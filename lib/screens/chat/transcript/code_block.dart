import 'dart:async';

import 'package:flutter/material.dart';

import '../../../i18n/strings.g.dart';
import 'code_style.dart';
import 'highlighter.dart';
import 'tool_card.dart' show codeSurface;
import 'transcript_actions.dart';

/// A block of code: an optional header with a label and a copy button, then the code in a horizontal scroll view,
/// optionally with a line-number gutter. Highlighting is a colour-only change that lands asynchronously, so the block
/// never changes height when it does; an unclosed (still streaming) block stays plain.
class CodeBlock extends StatefulWidget {
  const CodeBlock({
    super.key,
    required this.code,
    this.language,
    this.label,
    this.closed = true,
    this.lineNumbers,
    this.header = true,
  });

  final String code;

  /// highlight.js language; null for plain text.
  final String? language;

  /// Header text, typically the fence info string or a file name.
  final String? label;

  /// False while the block is still arriving.
  final bool closed;

  /// Gutter numbers, one per line of [code]; a null entry is an elided line.
  final List<int?>? lineNumbers;

  /// Shows the label and copy button.
  final bool header;

  @override
  State<CodeBlock> createState() => _CodeBlockState();
}

class _CodeBlockState extends State<CodeBlock> {
  HighlightRuns? _runs;
  bool _copied = false;
  Timer? _copiedReset;

  @override
  void initState() {
    super.initState();
    _highlight();
  }

  @override
  void didUpdateWidget(CodeBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.code != oldWidget.code || widget.language != oldWidget.language || widget.closed != oldWidget.closed) {
      _runs = null;
      _highlight();
    }
  }

  @override
  void dispose() {
    _copiedReset?.cancel();
    super.dispose();
  }

  void _highlight() {
    final language = widget.language;
    if (language == null || !widget.closed || widget.code.isEmpty) return;
    final highlighter = CodeHighlighter.instance;
    if (highlighter.isCached(language, widget.code)) {
      _runs = highlighter.cached(language, widget.code);
      return;
    }
    final code = widget.code;
    unawaited(
      highlighter.highlight(language, code).then((runs) {
        if (!mounted || runs == null || widget.code != code || widget.language != language) return;
        setState(() => _runs = runs);
      }),
    );
  }

  void _copy() {
    TranscriptScope.of(context).onCopy(widget.code);
    _copiedReset?.cancel();
    setState(() => _copied = true);
    _copiedReset = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final style = codeTextStyle(theme);
    final runs = _runs;
    final code = widget.code.endsWith('\n') ? widget.code.substring(0, widget.code.length - 1) : widget.code;
    final text = Text.rich(
      TextSpan(
        style: style,
        children: runs == null
            ? [TextSpan(text: code)]
            : highlightedSpans(code, runs, highlightTheme(theme.brightness)),
      ),
      softWrap: false,
    );
    final numbers = widget.lineNumbers;
    final body = numbers == null
        ? text
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectionContainer.disabled(
                child: Text(
                  numbers.map((number) => number?.toString() ?? '⋮').join('\n'),
                  textAlign: TextAlign.right,
                  style: style.copyWith(color: scheme.onSurfaceVariant.withValues(alpha: 0.7)),
                ),
              ),
              const SizedBox(width: 12),
              text,
            ],
          );
    final label = widget.label ?? widget.language ?? '';
    return DecoratedBox(
      decoration: BoxDecoration(color: codeSurface(context), borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.header)
            SelectionContainer.disabled(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 2, 2, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      iconSize: 16,
                      tooltip: _copied ? context.t.common.copied : context.t.transcript.copyCode,
                      onPressed: _copy,
                      icon: Icon(_copied ? Icons.check : Icons.copy_outlined),
                    ),
                  ],
                ),
              ),
            ),
          SideScrollView(padding: EdgeInsets.fromLTRB(12, widget.header ? 0 : 10, 12, 10), child: body),
        ],
      ),
    );
  }
}

/// A horizontal scroll view whose text is selectable as part of the selection container around it.
///
/// Under a [SelectionArea], a [Scrollable] adds a selection container of its own. A transcript row that holds a
/// selection (even the caret of a click) stays alive off screen with a zero paint transform; the container of a scroll
/// view in that row then takes a later press anywhere for one inside it, computes a NaN position and fails the drag
/// target assertion of `EdgeDraggingAutoScroller`. This view adds none: its text joins the container around it, like
/// the rest of the row's text. A drag past its edge does not scroll it sideways.
class SideScrollView extends StatelessWidget {
  const SideScrollView({super.key, this.controller, this.padding, required this.child});

  final ScrollController? controller;
  final EdgeInsetsGeometry? padding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final registrar = SelectionContainer.maybeOf(context);
    final view = SingleChildScrollView(
      controller: controller,
      scrollDirection: Axis.horizontal,
      padding: padding,
      child: registrar == null ? child : SelectionRegistrarScope(registrar: registrar, child: child),
    );
    return registrar == null ? view : SelectionContainer.disabled(child: view);
  }
}
