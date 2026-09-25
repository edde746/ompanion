import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omp_core/store.dart';

import '../../../i18n/strings.g.dart';
import 'ansi.dart';
import 'code_style.dart';
import 'tool_bodies.dart';
import 'transcript_rows.dart';

/// What a tool card knows about one call: its row, its result so far, and the session's subagents (a `task` card
/// shows their live status).
final class ToolData {
  ToolData({required this.row, required this.result, required this.subagents});

  final ToolRow row;
  final ToolResultItem? result;
  final List<Subagent> subagents;

  String get name => row.toolName;

  /// Arguments: the call's (complete once its message ended), else the ones `tool_execution_start` carried.
  late final Map<String, Object?> args = switch ((row.call?.arguments, result?.args)) {
    (final Map<String, Object?> arguments, _) when arguments.isNotEmpty => arguments,
    (_, final Map<String, Object?> args) => args,
    _ => const {},
  };

  /// The harness intent (`i`).
  String? get intent => row.call?.intent ?? result?.intent ?? switch (args['i']) {
    final String intent => intent,
    _ => null,
  };

  Object? get details => result?.details;

  /// Result text so far.
  String get text => result?.text ?? '';

  bool get isError => result?.isError ?? false;

  late final List<ImageBlock> images = result?.content.whereType<ImageBlock>().toList() ?? const [];

  late final ToolStatus status = switch (result?.state) {
    null when row.abandoned => ToolStatus.interrupted,
    null => ToolStatus.pending,
    ToolState.running => ToolStatus.running,
    ToolState.background => ToolStatus.background,
    ToolState.interrupted => ToolStatus.interrupted,
    ToolState.done => isError ? ToolStatus.failed : ToolStatus.done,
  };

  late final ToolKind kind = toolKindFor(name, args: args, details: details);
}

enum ToolStatus { pending, running, background, done, failed, interrupted }

/// The parts of a card that depend on the tool: the one-line [subject] (a command, a path, a query), short [meta]
/// facts after it, whether the body starts open, and the [body] shown when it is.
typedef ToolParts = ({
  String subject,
  bool monoSubject,
  List<String> meta,
  bool expanded,
  VoidCallback? open,
  WidgetBuilder? body,
});

/// A tool call with its result: a header (status, tool name, subject, facts) that toggles a tool-specific body.
/// Streaming partial results render through the same body as final ones.
class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.data});

  final ToolData data;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

class _ToolCardState extends State<ToolCard> {
  bool? _expanded;

  String get _storageId => 'transcript-tool-expanded:${widget.data.row.key}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expanded ??= PageStorage.maybeOf(context)?.readState(context, identifier: _storageId) as bool?;
  }

  void _toggle(bool expanded) {
    setState(() => _expanded = !expanded);
    PageStorage.maybeOf(context)?.writeState(context, !expanded, identifier: _storageId);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final data = widget.data;
    final parts = toolParts(context, data);
    final expanded = _expanded ?? (parts.expanded || data.status == ToolStatus.failed);
    final body = parts.body;
    final intent = data.intent;
    final subjectStyle = parts.monoSubject
        ? codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall?.fontSize)
        : theme.textTheme.bodyMedium;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: data.status == ToolStatus.failed ? scheme.error.withValues(alpha: 0.6) : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          SelectionContainer.disabled(
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: body == null ? null : () => _toggle(expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _StatusIcon(data.status),
                        const SizedBox(width: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 160),
                          child: Text(
                            data.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w600),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: parts.open == null
                              ? Text(parts.subject, maxLines: 1, overflow: TextOverflow.ellipsis, style: subjectStyle)
                              : InkWell(
                                  onTap: parts.open,
                                  child: Text(
                                    parts.subject,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: subjectStyle?.copyWith(
                                      color: scheme.primary,
                                      decoration: TextDecoration.underline,
                                      decorationColor: scheme.primary.withValues(alpha: 0.4),
                                    ),
                                  ),
                                ),
                        ),
                        for (final fact in parts.meta)
                          Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              fact,
                              style: theme.textTheme.labelSmall?.copyWith(
                                color: data.status == ToolStatus.failed ? scheme.error : scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        SizedBox(
                          width: 28,
                          child: body == null
                              ? null
                              : Icon(
                                  expanded ? Icons.expand_less : Icons.expand_more,
                                  size: 18,
                                  color: scheme.onSurfaceVariant,
                                ),
                        ),
                      ],
                    ),
                    if (intent != null && intent.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(left: 22, top: 2),
                        child: Text(
                          intent,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (expanded && body != null)
            Padding(padding: const EdgeInsets.fromLTRB(10, 0, 10, 10), child: body(context)),
        ],
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status);

  final ToolStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = context.t.transcript.tool;
    return SizedBox.square(
      dimension: 14,
      child: switch (status) {
        ToolStatus.pending || ToolStatus.running => Tooltip(
          message: t.running,
          child: const CircularProgressIndicator(strokeWidth: 2),
        ),
        ToolStatus.background => Tooltip(
          message: t.background,
          child: Icon(Icons.schedule, size: 14, color: scheme.primary),
        ),
        ToolStatus.done => Icon(Icons.check_circle, size: 14, color: AnsiPalette.of(scheme).foreground(2)),
        ToolStatus.failed => Tooltip(
          message: t.error,
          child: Icon(Icons.error, size: 14, color: scheme.error),
        ),
        ToolStatus.interrupted => Tooltip(
          message: t.interrupted,
          child: Icon(Icons.do_not_disturb_on_outlined, size: 14, color: scheme.onSurfaceVariant),
        ),
      },
    );
  }
}

/// A small caption above a part of a card body.
class ToolSection extends StatelessWidget {
  const ToolSection(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: SelectionContainer.disabled(
        child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

/// [lines] capped at [max] from the start, or from the end with [tail], with a button that shows the rest. The
/// [builder] renders lines `[start, end)`.
class CappedLines extends StatefulWidget {
  const CappedLines({super.key, required this.lines, required this.builder, this.max = 30, this.tail = false});

  final List<String> lines;
  final Widget Function(BuildContext context, int start, int end) builder;
  final int max;
  final bool tail;

  @override
  State<CappedLines> createState() => _CappedLinesState();
}

class _CappedLinesState extends State<CappedLines> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final count = widget.lines.length;
    if (count <= widget.max + 2) return widget.builder(context, 0, count);
    final hidden = count - widget.max;
    final toggle = SelectionContainer.disabled(
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
          onPressed: () => setState(() => _all = !_all),
          icon: Icon(_all ? Icons.unfold_less : Icons.unfold_more, size: 16),
          label: Text(_all ? context.t.transcript.showLess : context.t.transcript.showMoreLines(n: hidden)),
        ),
      ),
    );
    if (_all) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [widget.builder(context, 0, count), toggle],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: widget.tail
          ? [toggle, widget.builder(context, hidden, count)]
          : [widget.builder(context, 0, widget.max), toggle],
    );
  }
}

/// Lines of [text] without a trailing empty line.
List<String> linesOf(String text) {
  final lines = text.split('\n');
  if (lines.length > 1 && lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// Terminal output with ANSI colours, wrapped, on a code surface, the last [max] lines shown first.
class TerminalOutput extends StatelessWidget {
  const TerminalOutput(this.text, {super.key, this.max = 30, this.error = false});

  final String text;
  final int max;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final lines = linesOf(text);
    final base = codeTextStyle(theme).copyWith(color: error ? scheme.error : scheme.onSurface);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: CappedLines(
          lines: lines,
          max: max,
          tail: true,
          builder: (context, start, end) =>
              Text.rich(ansiSpan(lines.sublist(start, end).join('\n'), base: base, scheme: scheme)),
        ),
      ),
    );
  }
}

/// [value] as indented JSON on a code surface, capped.
class JsonView extends StatelessWidget {
  const JsonView(this.value, {super.key, this.max = 20});

  final Object? value;
  final int max;

  static const _encoder = JsonEncoder.withIndent('  ');

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = linesOf(_encoder.convert(value));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: CappedLines(
          lines: lines,
          max: max,
          builder: (context, start, end) =>
              Text(lines.sublist(start, end).join('\n'), style: codeTextStyle(theme)),
        ),
      ),
    );
  }
}
