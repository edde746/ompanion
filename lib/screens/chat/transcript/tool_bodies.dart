import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/store.dart';

import '../../../app/theme.dart';
import '../../../files/file_paths.dart';
import '../../../i18n/strings.g.dart';
import '../../../utils/compact_duration.dart';
import '../../../utils/token_count.dart';
import '../../../widgets/activity_mark.dart';
import '../mode_controls.dart' show goalStatusLabel, goalUsage;
import 'code_block.dart';
import 'diff.dart';
import 'highlighter.dart';
import 'images.dart';
import 'markdown.dart';
import 'tool_card.dart';
import 'transcript_actions.dart';
import 'transcript_rows.dart';

String? _string(Object? value) => value is String ? value : null;

Map<String, Object?>? _object(Object? value) => value is Map<String, Object?> ? value : null;

List<Object?> _list(Object? value) => value is List<Object?> ? value : const [];

int? _int(Object? value) => value is num ? value.toInt() : null;

String _firstLine(String text) {
  final newline = text.indexOf('\n');
  return newline == -1 ? text : '${text.substring(0, newline)} …';
}

/// The tool-specific parts of [data]'s card.
ToolParts toolParts(BuildContext context, ToolData data) => switch (data.kind) {
  ToolKind.bash => _bash(context, data),
  ToolKind.read => _read(context, data),
  ToolKind.fetch => _fetch(context, data),
  ToolKind.edit => _edit(context, data),
  ToolKind.write => _write(context, data),
  ToolKind.todo => _todo(context, data),
  ToolKind.task => _task(context, data),
  ToolKind.ask => _ask(context, data),
  ToolKind.webSearch => _webSearch(context, data),
  ToolKind.eval => _eval(context, data),
  ToolKind.goal => _goal(context, data),
  ToolKind.generic => _generic(context, data),
};

/// Footers omp appends to tool output for the model (`tui/src/tools/bash.ts`, `output-meta.ts`); the card shows the
/// same facts in its header.
final _notices = [
  RegExp(r'^Wall time: [\d.]+ seconds?$', multiLine: true),
  RegExp(r'^Command exited with code -?\d+$', multiLine: true),
  RegExp(r'^Backgrounded as job .*$', multiLine: true),
];

String _withoutNotices(String text) {
  var out = text;
  for (final notice in _notices) {
    final matches = notice.allMatches(out);
    if (matches.isEmpty) continue;
    final last = matches.last;
    out = out.substring(0, last.start) + out.substring(last.end);
  }
  return out.trimRight();
}

Widget _dim(BuildContext context, String text) {
  final theme = Theme.of(context);
  return Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant));
}

List<Widget> _errorAndImages(BuildContext context, ToolData data, {bool showText = true, bool showImages = true}) => [
  if (showText && data.isError && data.text.trim().isNotEmpty) ...[
    const SizedBox(height: 6),
    TerminalOutput(_withoutNotices(data.text), error: true),
  ],
  if (showImages && data.images.isNotEmpty) ...[const SizedBox(height: 8), ImageStrip(data.images)],
];

Widget _column(List<Widget> children) =>
    Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: children);

ToolParts _bash(BuildContext context, ToolData data) {
  final t = context.t.transcript;
  final command = _string(data.args['command']) ?? '';
  final details = _object(data.details);
  final exitCode = _int(details?['exitCode']);
  final timedOut = details?['timedOut'] == true;
  final wall = details?['wallTimeMs'];
  final output = _withoutNotices(data.text);
  // A thrown error replaces the output with its message; a failing command keeps its own output.
  final thrown = data.isError && exitCode == null && !timedOut;
  return (
    subject: '\$ ${_firstLine(command)}',
    monoSubject: true,
    meta: [
      if (timedOut) t.tool.timedOut,
      if (exitCode != null && exitCode != 0) t.tool.exitCode(code: exitCode),
      if (wall is num) t.seconds(value: (wall / 1000).toStringAsFixed(2)),
    ],
    expanded: true,
    open: null,
    body: (context) => _column([
      if (command.contains('\n')) ...[
        CodeBlock(code: command, language: 'bash', copyable: false),
        const SizedBox(height: 6),
      ],
      if (output.trim().isNotEmpty)
        TerminalOutput(output, error: thrown)
      else if (data.status == ToolStatus.done)
        _dim(context, t.tool.noOutput),
      ..._errorAndImages(context, data, showText: false),
    ]),
  );
}

/// A read path without its selector (`:50-100`, `:raw`, `:img`, `:conflicts`, `:-20`, comma lists).
String _withoutSelector(String path) {
  var out = path;
  final selector = RegExp(r':(?:raw|img|conflicts|-?\d[\d,+\-]*)$');
  while (true) {
    final match = selector.firstMatch(out);
    if (match == null || match.start == 0) return out;
    out = out.substring(0, match.start);
  }
}

/// The file behind a read: omp's resolved or source path when it reports one.
String _readTarget(Map<String, Object?>? details, String path) =>
    _string(details?['resolvedPath']) ??
    switch (details?['meta']) {
      {'source': {'type': 'path', 'value': final String value}} => value,
      _ => _withoutSelector(path),
    };

/// Extensions of the image files omp reads as images (`read` of a PNG, JPEG, GIF, WebP, …).
const _imageExtensions = {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp', 'tif', 'tiff', 'heic', 'heif', 'avif'};

/// `PNG` for `image/png`.
String _imageType(String mimeType) => mimeType.split('/').last.split(RegExp('[+;]')).first.toUpperCase();

ToolParts _read(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  final path = _string(data.args['path']) ?? _string(data.args['file_path']) ?? '';
  final details = _object(data.details);
  final display = _object(details?['displayContent']);
  final text = _string(display?['text']);
  final startLine = _int(display?['startLine']) ?? 1;
  final lines = text == null ? const <String>[] : linesOf(text);
  final numbers = [for (final number in _list(display?['lineNumbers'])) _int(number)];
  final gutter = numbers.length == lines.length ? numbers : [for (var i = 0; i < lines.length; i++) startLine + i];
  final shown = gutter.whereType<int>();
  final total = _int(details?['totalLines']);
  final target = _readTarget(details, path);
  // omp sends a read image only to a model that takes images; for another it sends the image's metadata as text, and
  // the card shows the file from the machine instead.
  final images = data.images;
  final fromMachine =
      images.isEmpty &&
      text == null &&
      data.status == ToolStatus.done &&
      _imageExtensions.contains(extensionOf(_withoutSelector(target)));
  // What the model got, which omp may have converted (a PNG arrives as WebP): the file's own facts are in Files.
  final pixels = images.isEmpty ? null : imageSize(images.first);
  return (
    subject: path,
    monoSubject: true,
    meta: [
      if (pixels != null) '${pixels.width.round()}×${pixels.height.round()}',
      if (images.isNotEmpty) _imageType(images.first.mimeType),
      if (shown.isNotEmpty && (shown.first != 1 || (total != null && shown.last != total)))
        t.lineRange(from: shown.first, to: shown.last)
      else if (total != null)
        t.lines(n: total),
    ],
    expanded: images.isNotEmpty || fromMachine,
    open: path.isEmpty ? null : () => TranscriptScope.of(context).onOpenFile(target, line: startLine),
    body: (context) => _column([
      if (text != null)
        CappedLines(
          lines: lines,
          max: 20,
          builder: (context, start, end) => CodeBlock(
            code: lines.sublist(start, end).join('\n'),
            language: languageForPath(_withoutSelector(path)),
            lineNumbers: gutter.sublist(start, end),
            copyable: false,
          ),
        )
      else if (images.isEmpty && !data.isError && data.text.trim().isNotEmpty)
        TerminalOutput(data.text, max: 20),
      for (final (index, image) in images.indexed) ...[
        if (index > 0) const SizedBox(height: 8),
        FittedImage(imageBytes(image)),
      ],
      if (fromMachine) ...[const SizedBox(height: 8), MachineImage(path: _withoutSelector(target), caption: false)],
      ..._errorAndImages(context, data, showImages: false),
    ]),
  );
}

ToolParts _fetch(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  final details = _object(data.details);
  final url = _string(details?['url']) ?? _string(data.args['url']) ?? _string(data.args['path']) ?? '';
  final finalUrl = _string(details?['finalUrl']);
  final contentType = _string(details?['contentType']);
  // The read output is a header block, a `---` rule, then the page (`buildUrlReadOutput`, `tools/fetch.ts`).
  final separator = data.text.indexOf('\n---\n');
  final page = (separator == -1 ? data.text : data.text.substring(separator + 5)).trim();
  final uri = Uri.tryParse(url);
  return (
    subject: url,
    monoSubject: false,
    meta: [?contentType?.split(';').first],
    expanded: false,
    open: uri == null || !uri.hasScheme ? null : () => openTranscriptLink(context, url),
    body: (context) => _column([
      if (finalUrl != null && finalUrl != url) _dim(context, t.redirectedTo(url: finalUrl)),
      if (!data.isError && page.isNotEmpty) ...[const SizedBox(height: 4), TerminalOutput(page, max: 12)],
      ..._errorAndImages(context, data),
    ]),
  );
}

final _hashlineHeader = RegExp(r'^\[([^\]#\n]+)#[0-9A-Za-z]+\]', multiLine: true);
final _patchHeader = RegExp(r'^\*\*\* (?:Add|Update|Delete) File: (.+)$', multiLine: true);

/// The path an edit call names: a plain argument, or the first file of a hashline or apply_patch input.
String? _editPath(Map<String, Object?> args) {
  final path = _string(args['path']) ?? _string(args['file_path']);
  if (path != null) return path;
  final input = _string(args['input']) ?? _string(args['patch']) ?? '';
  return (_hashlineHeader.firstMatch(input) ?? _patchHeader.firstMatch(input))?[1]?.trim();
}

/// One file of an edit result: its path, diff and what happened to it.
typedef _EditFile = ({String? path, String diff, String? op, String? move, int? line, String? error});

_EditFile _editFile(Map<String, Object?> file) => (
  path: _string(file['path']),
  diff: _string(file['diff']) ?? '',
  op: _string(file['op']),
  move: _string(file['move']) ?? _string(file['rename']),
  line: _int(file['firstChangedLine']),
  error: _string(file['displayErrorText']) ?? _string(file['errorText']) ?? _string(file['error']),
);

ToolParts _edit(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  final details = _object(data.details);
  final files = <_EditFile>[
    for (final file in _list(details?['perFileResults']))
      if (_object(file) case final file?) _editFile(file),
  ];
  if (files.isEmpty && details != null && details['diff'] is String) files.add(_editFile(details));
  // While the arguments stream, omp previews the edit (`tool_stream_update`, an `EditPreviewBatch`).
  final previews = [
    if (files.isEmpty)
      for (final file in _list(_object(data.result?.streamUpdate)?['files']))
        if (_object(file) case final file?) _editFile(file),
  ];
  final shown = files.isNotEmpty ? files : previews;
  final parsed = [for (final file in shown) (file, parseOmpDiff(file.diff))];
  var added = 0, removed = 0;
  for (final (_, rows) in parsed) {
    for (final row in rows) {
      if (row.kind == DiffLineKind.added) added++;
      if (row.kind == DiffLineKind.removed) removed++;
    }
  }
  final path = _editPath(data.args) ?? (shown.isEmpty ? null : shown.first.path) ?? '';
  final target = shown.isEmpty ? null : shown.first.path;
  final op = shown.isEmpty ? null : shown.first.op;
  final diagnostics = _list(_object(details?['diagnostics'])?['messages']).whereType<String>().toList();
  final input = _string(data.args['input']) ?? _string(data.args['patch']);
  return (
    subject: path,
    monoSubject: true,
    meta: [if (op == 'create') t.created, if (op == 'delete') t.deleted, if (added + removed > 0) '+$added −$removed'],
    expanded: true,
    open: path.isEmpty
        ? null
        : () => TranscriptScope.of(context).onOpenFile(target ?? path, line: shown.firstOrNull?.line),
    body: (context) => _column([
      for (final (file, rows) in parsed) ...[
        if (parsed.length > 1 && file.path != null) ToolSection(file.path!),
        if (file.move != null) _dim(context, t.movedTo(path: file.move!)),
        if (file.error != null) TerminalOutput(file.error!, error: true),
        if (rows.isNotEmpty)
          CappedLines(
            lines: [for (final row in rows) row.text],
            max: 60,
            builder: (context, start, end) => ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: DiffView(lines: rows.sublist(start, end)),
            ),
          )
        else if (file.error == null && data.status == ToolStatus.done)
          _dim(context, t.noChanges),
      ],
      if (parsed.isEmpty && !data.isError && input != null) TerminalOutput(input, max: 20),
      if (parsed.isEmpty && !data.isError && input == null && data.args.isNotEmpty) JsonView(data.args),
      if (diagnostics.isNotEmpty) ...[
        ToolSection(t.diagnostics),
        for (final message in diagnostics) _dim(context, message),
      ],
      ..._errorAndImages(context, data),
    ]),
  );
}

ToolParts _write(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  final path = _string(data.args['path']) ?? _string(data.args['file_path']) ?? '';
  final content = _string(data.args['content']) ?? '';
  final lines = linesOf(content);
  final details = _object(data.details);
  final diagnostics = _list(_object(details?['diagnostics'])?['messages']).whereType<String>().toList();
  return (
    subject: path,
    monoSubject: true,
    meta: [if (content.isNotEmpty) t.lines(n: lines.length)],
    expanded: false,
    open: path.isEmpty ? null : () => TranscriptScope.of(context).onOpenFile(_string(details?['resolvedPath']) ?? path),
    body: (context) => _column([
      if (content.isNotEmpty)
        CappedLines(
          lines: lines,
          max: 20,
          builder: (context, start, end) => CodeBlock(
            code: lines.sublist(start, end).join('\n'),
            language: languageForPath(path),
            lineNumbers: [for (var line = start + 1; line <= end; line++) line],
            copyable: false,
          ),
        ),
      if (diagnostics.isNotEmpty) ...[
        ToolSection(t.diagnostics),
        for (final message in diagnostics) _dim(context, message),
      ],
      ..._errorAndImages(context, data),
    ]),
  );
}

/// A todo task as omp's `todo` details carry it (`TodoItem`, `tui/src/tools/todo.ts`).
typedef _Todo = ({String content, TodoStatus status, String? blocker});

TodoStatus _todoStatus(String? status) => switch (status) {
  'in_progress' => TodoStatus.inProgress,
  'completed' => TodoStatus.completed,
  'abandoned' || 'dropped' => TodoStatus.abandoned,
  'blocked' => TodoStatus.blocked,
  _ => TodoStatus.pending,
};

ToolParts _todo(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  final details = _object(data.details);
  var phases = <(String, List<_Todo>)>[
    for (final phase in _list(details?['phases']))
      if (_object(phase) case final phase?)
        (
          _string(phase['name']) ?? '',
          [
            for (final task in _list(phase['tasks']))
              if (_object(task) case final task?)
                (
                  content: _string(task['content']) ?? '',
                  status: _todoStatus(_string(task['status'])),
                  blocker: _string(task['blocker']),
                ),
          ],
        ),
  ];
  if (phases.isEmpty) {
    // No result yet: the planned list from the arguments.
    phases = [
      for (final phase in _list(data.args['list']))
        if (_object(phase) case final phase?)
          (
            _string(phase['phase']) ?? '',
            [
              for (final item in _list(phase['items']))
                if (item is String) (content: item, status: TodoStatus.pending, blocker: null),
            ],
          ),
      if (_list(data.args['items']).isNotEmpty)
        (
          _string(data.args['phase']) ?? '',
          [
            for (final item in _list(data.args['items']))
              if (item is String) (content: item, status: TodoStatus.pending, blocker: null),
          ],
        ),
    ];
  }
  final tasks = phases.expand((phase) => phase.$2).toList();
  final done = tasks.where((task) => task.status == TodoStatus.completed).length;
  final op = _string(details?['op']) ?? _string(data.args['op']) ?? '';
  final subject = [op, ?_string(data.args['task']) ?? _string(data.args['phase'])].where((part) => part.isNotEmpty);
  return (
    subject: subject.join(' · '),
    monoSubject: false,
    meta: [if (tasks.isNotEmpty) t.todoProgress(done: done, total: tasks.length)],
    // The plan shows once, where it is made; each update after it is one line: what changed and the count. Images
    // the call returned show whatever the op.
    expanded: op == 'init' || data.images.isNotEmpty,
    open: null,
    body: phases.isEmpty && data.images.isEmpty
        ? null
        : (context) => _column([
            for (final (name, tasks) in phases) ...[
              if (name.isNotEmpty) ToolSection(name),
              for (final task in tasks) _TodoRow(task),
            ],
            ..._errorAndImages(context, data),
          ]),
  );
}

class _TodoRow extends StatelessWidget {
  const _TodoRow(this.task);

  final _Todo task;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final (icon, color) = switch (task.status) {
      TodoStatus.pending => (Symbols.radio_button_unchecked, scheme.onSurfaceVariant),
      TodoStatus.inProgress => (Symbols.play_circle, scheme.onSurface),
      TodoStatus.completed => (Symbols.check_circle, AppColors.of(context).success),
      TodoStatus.abandoned => (Symbols.cancel, scheme.onSurfaceVariant),
      TodoStatus.blocked => (Symbols.block, AppColors.of(context).error),
    };
    final crossed = task.status == TodoStatus.completed || task.status == TodoStatus.abandoned;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(icon, size: 14, color: color, fill: task.status == TodoStatus.completed ? 1 : 0),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // The small text of the tool bodies around it: a plan is a list of work, not prose.
                Text(
                  task.content,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: crossed ? scheme.onSurfaceVariant : scheme.onSurface,
                    decoration: crossed ? TextDecoration.lineThrough : null,
                    fontWeight: task.status == TodoStatus.inProgress ? FontWeight.w600 : null,
                  ),
                ),
                if (task.blocker != null)
                  Text(task.blocker!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).error)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One subagent of a `task` call: from the live subagent list, the call's progress, its results, or its arguments.
typedef _Agent = ({
  String id,
  String agent,
  SubagentStatus status,
  String task,
  String? activity,
  int? tokens,
  Duration? duration,
});

SubagentStatus _subagentStatus(String? status) => switch (status) {
  'running' => SubagentStatus.running,
  'completed' => SubagentStatus.completed,
  'failed' => SubagentStatus.failed,
  'aborted' => SubagentStatus.aborted,
  _ => SubagentStatus.pending,
};

List<_Agent> _agents(ToolData data) {
  final details = _object(data.details);
  final live = {for (final subagent in data.subagents) subagent.id: subagent};
  final agents = <_Agent>[];
  final progress = [for (final entry in _list(details?['progress'])) ?_object(entry)];
  final results = {
    for (final result in [for (final entry in _list(details?['results'])) ?_object(entry)])
      _string(result['id']) ?? '': result,
  };
  final entries = progress.isNotEmpty ? progress : results.values.toList();
  for (final entry in entries) {
    final id = _string(entry['id']) ?? '';
    final subagent = live[id];
    final result = results[id];
    final status =
        subagent?.status ??
        switch (result) {
          null => _subagentStatus(_string(entry['status'])),
          {'aborted': true} => SubagentStatus.aborted,
          {'error': final String _} => SubagentStatus.failed,
          _ => _int(result['exitCode']) == 0 ? SubagentStatus.completed : SubagentStatus.failed,
        };
    final progressOf = subagent?.progress;
    agents.add((
      id: id,
      agent: subagent?.agent ?? _string(entry['agent']) ?? '',
      status: status,
      task:
          subagent?.description ??
          _string(entry['description']) ??
          subagent?.assignment ??
          _string(entry['assignment']) ??
          _string(entry['task']) ??
          '',
      activity: progressOf?.lastIntent ?? progressOf?.currentTool ?? _string(entry['lastIntent']),
      tokens: progressOf?.tokens ?? _int(entry['tokens']),
      duration:
          progressOf?.duration ??
          switch (_int(entry['durationMs'])) {
            final int ms when ms > 0 => Duration(milliseconds: ms),
            _ => null,
          },
    ));
  }
  if (agents.isNotEmpty) return agents;
  // Not started yet: the requested tasks from the arguments (batch or flat form).
  final tasks = _list(data.args['tasks']).isNotEmpty ? _list(data.args['tasks']) : [data.args];
  return [
    for (final task in tasks)
      if (_object(task) case final task? when _string(task['task']) != null)
        (
          id: _string(task['name']) ?? '',
          agent: _string(task['agent']) ?? 'task',
          status: SubagentStatus.pending,
          task: _string(task['task'])!,
          activity: null,
          tokens: null,
          duration: null,
        ),
  ];
}

ToolParts _task(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  final agents = _agents(data);
  final contextText = _string(data.args['context']);
  return (
    subject: agents.length == 1 ? [agents.single.id, agents.single.agent].where((s) => s.isNotEmpty).join(' · ') : '',
    monoSubject: false,
    meta: [if (agents.length > 1) t.agents(n: agents.length)],
    expanded: true,
    open: null,
    body: (context) => _column([
      for (final agent in agents) _AgentRow(agent),
      if (contextText != null && contextText.trim().isNotEmpty) ...[
        ToolSection(t.context),
        CappedLines(
          lines: linesOf(contextText),
          max: 4,
          builder: (context, start, end) => _dim(context, linesOf(contextText).sublist(start, end).join('\n')),
        ),
      ],
      ..._errorAndImages(context, data),
    ]),
  );
}

class _AgentRow extends StatelessWidget {
  const _AgentRow(this.agent);

  final _Agent agent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript.tool;
    final (label, color) = switch (agent.status) {
      SubagentStatus.pending => (t.agentPending, scheme.onSurfaceVariant),
      SubagentStatus.running => (t.agentRunning, scheme.onSurface),
      SubagentStatus.completed => (t.agentCompleted, AppColors.of(context).success),
      SubagentStatus.failed => (t.agentFailed, AppColors.of(context).error),
      SubagentStatus.aborted => (t.agentAborted, scheme.onSurfaceVariant),
    };
    final facts = [
      if (agent.tokens case final tokens? when tokens > 0)
        context.t.transcript.tool.tokens(count: formatTokens(tokens)),
      if (agent.duration != null)
        context.t.transcript.seconds(value: (agent.duration!.inMilliseconds / 1000).toStringAsFixed(1)),
    ];
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: agent.id.isEmpty ? null : () => TranscriptScope.of(context).onOpenSubagent(agent.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: agent.status == SubagentStatus.running
                  ? const ActivityMark()
                  : Icon(Symbols.smart_toy, size: 14, color: color),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          text: agent.id,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        TextSpan(
                          text: '  ${agent.agent}  ',
                          style: TextStyle(color: scheme.onSurfaceVariant),
                        ),
                        TextSpan(
                          text: label,
                          style: TextStyle(color: color),
                        ),
                        if (facts.isNotEmpty)
                          TextSpan(
                            text: '  ${facts.join(' · ')}',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                    style: theme.textTheme.bodySmall,
                  ),
                  if (agent.task.isNotEmpty)
                    Text(
                      agent.task,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  if (agent.activity != null && agent.status == SubagentStatus.running)
                    Text(
                      agent.activity!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                ],
              ),
            ),
            if (agent.id.isNotEmpty)
              Tooltip(
                message: t.openAgent,
                child: Icon(Symbols.chevron_right, size: 18, color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

/// A question of an `ask` call with its answer (`QuestionResult`, `tui/src/tools/ask.ts`).
typedef _Question = ({
  String question,
  String? header,
  List<(String, String?)> options,
  int? recommended,
  List<String> selected,
  String? custom,
  String? note,
  bool timedOut,
  bool answered,
});

List<_Question> _questions(ToolData data) {
  final details = _object(data.details);
  final results = <Map<String, Object?>>[
    for (final result in _list(details?['results'])) ?_object(result),
    if (details != null && details['question'] is String) details,
  ];
  final asked = [for (final question in _list(data.args['questions'])) ?_object(question)];
  final count = asked.length > results.length ? asked.length : results.length;
  return [
    for (var i = 0; i < count; i++)
      () {
        final question = i < asked.length ? asked[i] : const <String, Object?>{};
        final id = _string(question['id']);
        final result =
            results.where((result) => id != null && result['id'] == id).firstOrNull ??
            (i < results.length ? results[i] : null);
        final options = <(String, String?)>[
          for (final option in _list(question['options']))
            if (_object(option) case final option?)
              (_string(option['label']) ?? '', _string(option['description']))
            else if (option is String)
              (option, null),
        ];
        if (options.isEmpty) {
          for (final option in _list(result?['options'])) {
            if (option is String) options.add((option, null));
          }
        }
        return (
          question: _string(question['question']) ?? _string(result?['question']) ?? '',
          header: _string(question['header']),
          options: options,
          recommended: _int(question['recommended']),
          selected: [for (final option in _list(result?['selectedOptions'])) ?_string(option)],
          custom: _string(result?['customInput']),
          note: _string(result?['note']),
          timedOut: result?['timedOut'] == true,
          answered: result != null,
        );
      }(),
  ];
}

ToolParts _ask(BuildContext context, ToolData data) {
  final done = data.status != ToolStatus.pending && data.status != ToolStatus.running;
  // While the call waits, the question and its options are answered in the request panel under the transcript.
  if (!done) {
    return (
      subject: context.t.transcript.tool.askWaiting,
      monoSubject: false,
      meta: const [],
      expanded: false,
      open: null,
      body: null,
    );
  }
  final questions = _questions(data);
  return (
    subject: questions.isEmpty ? '' : questions.first.question,
    monoSubject: false,
    meta: const [],
    expanded: true,
    open: null,
    body: (context) =>
        _column([for (final question in questions) _QuestionView(question), ..._errorAndImages(context, data)]),
  );
}

class _QuestionView extends StatelessWidget {
  const _QuestionView(this.question);

  final _Question question;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.transcript.tool;
    // Shown once the call finished: an answered question without a choice was cancelled.
    final cancelled = question.answered && question.selected.isEmpty && question.custom == null;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (question.header != null)
            Text(question.header!, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
          Text(question.question, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          for (final (index, (label, description)) in question.options.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      question.selected.contains(label) ? Symbols.check_circle : Symbols.circle,
                      size: 16,
                      color: question.selected.contains(label) ? scheme.onSurface : scheme.onSurfaceVariant,
                      fill: question.selected.contains(label) ? 1 : 0,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: label,
                            style: TextStyle(fontWeight: question.selected.contains(label) ? FontWeight.w600 : null),
                          ),
                          if (index == question.recommended)
                            TextSpan(
                              text: '  ${t.recommended}',
                              style: TextStyle(
                                color: scheme.onSurfaceVariant,
                                fontSize: theme.textTheme.labelSmall?.fontSize,
                              ),
                            ),
                          if (description != null)
                            TextSpan(
                              text: '\n$description',
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                        ],
                      ),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          if (question.custom != null)
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Symbols.edit_note, size: 16, color: scheme.onSurface),
                  const SizedBox(width: 8),
                  Expanded(child: Text('“${question.custom}”', style: theme.textTheme.bodySmall)),
                ],
              ),
            ),
          if (question.note != null) _dim(context, t.note(note: question.note!)),
          if (question.timedOut) _dim(context, t.autoSelected),
          if (cancelled) _dim(context, t.cancelled),
        ],
      ),
    );
  }
}

ToolParts _webSearch(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  final details = _object(data.details);
  final response = _object(details?['response']);
  final answer = _string(response?['answer']);
  final sources = [for (final source in _list(response?['sources'])) ?_object(source)];
  final error = _string(details?['error']);
  return (
    subject: _string(data.args['query']) ?? '',
    monoSubject: false,
    meta: [if (sources.isNotEmpty) t.sources(n: sources.length)],
    expanded: true,
    open: null,
    body: response == null && error == null && !data.isError && data.images.isEmpty
        ? null
        : (context) => _column([
            if (answer != null && answer.trim().isNotEmpty) TranscriptMarkdown(answer),
            for (final source in sources) _SourceRow(source),
            if (error != null) TerminalOutput(error, error: true),
            ..._errorAndImages(context, data, showText: error == null),
          ]),
  );
}

class _SourceRow extends StatelessWidget {
  const _SourceRow(this.source);

  final Map<String, Object?> source;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final url = _string(source['url']) ?? '';
    final title = _string(source['title']) ?? url;
    final snippet = _string(source['snippet']);
    final host = Uri.tryParse(url)?.host ?? '';
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: url.isEmpty ? null : () => openTranscriptLink(context, url),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                decoration: TextDecoration.underline,
                decorationColor: scheme.onSurfaceVariant,
              ),
            ),
            if (host.isNotEmpty)
              Text(host, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
            if (snippet != null)
              Text(snippet, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

String? _evalLanguage(String? language) => switch (language) {
  'py' || 'python' || 'ipython' => 'python',
  'js' || 'javascript' || 'ts' || 'typescript' => 'javascript',
  _ => null,
};

ToolParts _eval(BuildContext context, ToolData data) {
  final details = _object(data.details);
  final cells = [for (final cell in _list(details?['cells'])) ?_object(cell)];
  final code = _string(data.args['code']) ?? '';
  final language = _evalLanguage(
    _string(data.args['language']) ?? _string(details?['language']) ?? (data.name == 'python' ? 'python' : null),
  );
  final title = _string(data.args['title']);
  final jsonOutputs = _list(details?['jsonOutputs']);
  final liveImages = [
    for (final image in _list(details?['images']))
      if (_object(image) case {'data': final String bytes, 'mimeType': final String mime})
        ImageBlock(data: bytes, mimeType: mime),
  ];
  final output = _withoutNotices(data.text);
  return (
    subject: title ?? _firstLine(code),
    monoSubject: title == null,
    meta: [?_string(data.args['language'])],
    expanded: true,
    open: null,
    body: (context) => _column([
      if (cells.isNotEmpty)
        for (final cell in cells) ...[
          if (_string(cell['title']) case final title?) ToolSection(title),
          CodeBlock(code: _string(cell['code']) ?? '', language: _evalLanguage(_string(cell['language'])) ?? language),
          if ((_string(cell['output']) ?? '').trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            TerminalOutput(_string(cell['output'])!, error: cell['status'] == 'error'),
          ],
          const SizedBox(height: 6),
        ]
      else ...[
        if (code.isNotEmpty) CodeBlock(code: code, language: language),
        if (output.trim().isNotEmpty) ...[const SizedBox(height: 6), TerminalOutput(output, error: data.isError)],
      ],
      if (jsonOutputs.isNotEmpty) ...[const SizedBox(height: 6), for (final value in jsonOutputs) JsonView(value)],
      if (liveImages.isNotEmpty && data.images.isEmpty) ...[const SizedBox(height: 8), ImageStrip(liveImages)],
      ..._errorAndImages(context, data, showText: false),
    ]),
  );
}

/// The `goal` tool (`packages/tui/src/tools/goal.ts`): what the call did and the goal's status on its line; the
/// objective, its usage and a completion's report in the body.
ToolParts _goal(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  final details = _object(data.details);
  final op = _string(details?['op']) ?? _string(data.args['op']);
  final goal = _object(details?['goal']);
  final status = switch (_string(goal?['status'])) {
    'active' => GoalStatus.active,
    'paused' => GoalStatus.paused,
    'budget-limited' => GoalStatus.budgetLimited,
    'complete' => GoalStatus.complete,
    'dropped' => GoalStatus.dropped,
    _ => null,
  };
  final objective = _string(goal?['objective']) ?? _string(data.args['objective']);
  final used = _int(goal?['tokensUsed']);
  final seconds = _int(goal?['timeUsedSeconds']) ?? 0;
  final report = _string(details?['completionBudgetReport']);
  return (
    subject: switch (op) {
      'create' => t.goalSet,
      'get' => t.goalCheck,
      'complete' => t.goalComplete,
      'resume' => t.goalResume,
      'drop' => t.goalDrop,
      _ => op ?? '',
    },
    monoSubject: false,
    // The status, unless the op already says it: `complete` completes, `drop` drops.
    meta: [
      if (status == null && data.status == ToolStatus.done)
        t.goalNone
      else if (status != null &&
          !(op == 'complete' && status == GoalStatus.complete) &&
          !(op == 'drop' && status == GoalStatus.dropped))
        goalStatusLabel(context, status),
    ],
    expanded: false,
    open: null,
    body: objective == null && !data.isError
        ? null
        : (context) => _column([
            if (objective != null) TranscriptMarkdown(objective),
            if (used != null) ...[
              const SizedBox(height: 6),
              _dim(
                context,
                [
                  goalUsage(context, used, _int(goal?['tokenBudget'])),
                  if (seconds > 0) t.goalElapsed(time: compactDuration(Duration(seconds: seconds))),
                ].join('  ·  '),
              ),
            ],
            if (report != null && report.isNotEmpty) ...[ToolSection(t.report), _dim(context, report)],
            ..._errorAndImages(context, data),
          ]),
  );
}

ToolParts _generic(BuildContext context, ToolData data) {
  final t = context.t.transcript.tool;
  var args = data.args;
  var subject = '';
  final path = _string(args['path']);
  if (data.name == 'write' && path != null && path.startsWith('xd://')) {
    // An xd:// device call: the device's own arguments travel as JSON in `content`.
    subject = path;
    final content = _string(args['content']);
    if (content != null) args = _jsonObject(content) ?? args;
  } else {
    for (final MapEntry(:key, :value) in args.entries) {
      if (key != 'i' && value is String && value.isNotEmpty) {
        subject = _firstLine(value);
        break;
      }
    }
  }
  final arguments = {
    for (final MapEntry(:key, :value) in args.entries)
      if (key != 'i') key: value,
  };
  final text = _withoutNotices(data.text);
  return (
    subject: subject,
    monoSubject: true,
    meta: const [],
    expanded: false,
    open: null,
    body: (context) => _column([
      if (arguments.isNotEmpty) ...[ToolSection(t.arguments), JsonView(arguments)],
      if (text.trim().isNotEmpty) ...[
        ToolSection(t.output),
        TerminalOutput(text, max: 20, error: data.isError),
      ] else if (data.status == ToolStatus.done)
        _dim(context, t.noOutput),
      ..._errorAndImages(context, data, showText: false),
    ]),
  );
}

/// [text] decoded as a JSON object, or null when it is not one.
Map<String, Object?>? _jsonObject(String text) {
  try {
    return _object(jsonDecode(text));
  } on FormatException {
    return null;
  }
}
