import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/store.dart';

import '../../../app/theme.dart';
import '../../../i18n/strings.g.dart';
import '../../../widgets/activity_mark.dart';
import 'ansi.dart';
import 'code_style.dart';
import 'tool_bodies.dart';
import 'transcript_rows.dart';

/// A flat card of the transcript: a [ColorScheme.surfaceContainer] block without a border. Code, output and diffs
/// inside it sit one tone higher ([codeSurface]).
class TranscriptCard extends StatelessWidget {
  const TranscriptCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(AppSizes.cardRadius),
    ),
    child: child,
  );
}

/// The background of code, terminal output and diffs: [ColorScheme.surfaceContainer] on the transcript, one tone
/// higher inside a [TranscriptCard].
Color codeSurface(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return context.findAncestorWidgetOfExactType<TranscriptCard>() == null
      ? scheme.surfaceContainer
      : scheme.surfaceContainerHigh;
}

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
  String? get intent =>
      row.call?.intent ??
      result?.intent ??
      switch (args['i']) {
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

/// A tool call with its result: one flat line (status, tool name, subject, intent, facts) that toggles a
/// tool-specific body under it, indented to the tool's name. Streaming partial results render through the same body
/// as final ones.
class ToolCard extends StatefulWidget {
  const ToolCard({super.key, required this.data});

  final ToolData data;

  @override
  State<ToolCard> createState() => _ToolCardState();
}

/// Where a tool card's body starts: past the status mark and its gap, under the tool's name.
const toolBodyIndent = 22.0;

class _ToolCardState extends State<ToolCard> {
  bool? _expanded;
  final _open = TapGestureRecognizer();

  String get _storageId => 'transcript-tool-expanded:${widget.data.row.key}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _expanded ??= PageStorage.maybeOf(context)?.readState(context, identifier: _storageId) as bool?;
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
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
    final small = theme.textTheme.bodySmall;
    final mono = codeTextStyle(theme).copyWith(fontSize: small?.fontSize);
    final muted = scheme.onSurfaceVariant;
    final subjectStyle = (parts.monoSubject ? mono : small)?.copyWith(color: muted);
    _open.onTap = parts.open;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SelectionContainer.disabled(
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            onTap: body == null ? null : () => _toggle(expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                children: [
                  _StatusMark(data.status),
                  const SizedBox(width: toolBodyIndent - 14),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 160),
                    child: Text(
                      data.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: mono.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // The subject, then the harness intent in what room is left: one line, cut at its end.
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          if (parts.subject.isNotEmpty)
                            TextSpan(
                              text: parts.subject,
                              style: parts.open == null
                                  ? subjectStyle
                                  : subjectStyle?.copyWith(
                                      decoration: TextDecoration.underline,
                                      decorationColor: muted.withValues(alpha: 0.5),
                                    ),
                              recognizer: parts.open == null ? null : _open,
                              mouseCursor: parts.open == null ? null : SystemMouseCursors.click,
                            ),
                          if (intent != null && intent.isNotEmpty)
                            TextSpan(
                              text: parts.subject.isEmpty ? intent : '   $intent',
                              style: small?.copyWith(color: muted.withValues(alpha: 0.7)),
                            ),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  for (final fact in parts.meta)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Text(
                        fact,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: data.status == ToolStatus.failed ? AppColors.of(context).error : muted,
                        ),
                      ),
                    ),
                  SizedBox(
                    width: 24,
                    child: body == null
                        ? null
                        : Icon(expanded ? Symbols.expand_less : Symbols.expand_more, size: 16, color: muted),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded && body != null)
          Padding(padding: const EdgeInsets.fromLTRB(toolBodyIndent, 2, 0, 6), child: body(context)),
      ],
    );
  }
}

/// The start of a tool line: the activity mark while the call runs, else a 6 px dot, `success` when it is done,
/// `error` when it failed, `onSurfaceVariant` when it was interrupted.
class _StatusMark extends StatelessWidget {
  const _StatusMark(this.status);

  final ToolStatus status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final colors = AppColors.of(context);
    final t = context.t.transcript.tool;
    Widget dot(Color color) => Center(
      child: DecoratedBox(
        decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        child: const SizedBox.square(dimension: 6),
      ),
    );
    return SizedBox.square(
      dimension: 14,
      child: switch (status) {
        ToolStatus.pending || ToolStatus.running => Tooltip(
          message: t.running,
          child: ActivityMark(color: colors.running),
        ),
        ToolStatus.background => Tooltip(
          message: t.background,
          child: Icon(Symbols.schedule, size: 14, color: colors.running),
        ),
        ToolStatus.done => dot(colors.success),
        ToolStatus.failed => Tooltip(message: t.error, child: dot(colors.error)),
        ToolStatus.interrupted => Tooltip(message: t.interrupted, child: dot(scheme.onSurfaceVariant)),
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
          icon: Icon(_all ? Symbols.unfold_less : Symbols.unfold_more, size: 16),
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
    final base = codeTextStyle(theme).copyWith(color: error ? AppColors.of(context).error : scheme.onSurface);
    return DecoratedBox(
      decoration: BoxDecoration(color: codeSurface(context), borderRadius: BorderRadius.circular(AppSizes.radius)),
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
      decoration: BoxDecoration(color: codeSurface(context), borderRadius: BorderRadius.circular(AppSizes.radius)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: CappedLines(
          lines: lines,
          max: max,
          builder: (context, start, end) => Text(lines.sublist(start, end).join('\n'), style: codeTextStyle(theme)),
        ),
      ),
    );
  }
}
