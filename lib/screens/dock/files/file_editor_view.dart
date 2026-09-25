import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/host.dart';
import 'package:re_editor/re_editor.dart';

import '../../../files/file_document.dart';
import '../../../files/file_language.dart';
import '../../../files/file_paths.dart';
import '../../../files/file_workspace.dart';
import '../../../files/git_status.dart';
import '../../../i18n/strings.g.dart';
import '../../chat/transcript/code_style.dart';
import '../../chat/transcript/diff.dart';
import '../../chat/transcript/highlighter.dart';

/// One open document: the editor (read-only for large, binary or non-UTF-8 files), save with a conflict check, and
/// the file's `git diff` against HEAD.
class FileEditorView extends StatefulWidget {
  const FileEditorView({super.key, required this.workspace, required this.document});

  final FileWorkspace workspace;
  final FileDocument document;

  @override
  State<FileEditorView> createState() => _FileEditorViewState();
}

class _FileEditorViewState extends State<FileEditorView> {
  final _scroll = CodeScrollController();
  late CodeFindController _find = CodeFindController(widget.document.controller);
  var _showDiff = false;
  Future<String>? _diff;

  @override
  void initState() {
    super.initState();
    _revealPendingLine();
  }

  @override
  void didUpdateWidget(FileEditorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.document, widget.document)) {
      _find.dispose();
      _find = CodeFindController(widget.document.controller);
      _showDiff = false;
      _diff = null;
    }
    _revealPendingLine();
  }

  /// A line asked for with the file: select it and center it once the editor has laid out.
  void _revealPendingLine() {
    final document = widget.document;
    final line = document.pendingLine;
    if (line == null) return;
    document.pendingLine = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final index = (line - 1).clamp(0, document.controller.lineCount - 1);
      document.controller.selectLine(index);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) document.controller.makeCursorCenterIfInvisible();
      });
    });
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _save({bool force = false}) async {
    final t = context.t.dock.fileBrowser;
    final document = widget.document;
    if (document.readOnly || document.saving) return;
    try {
      await widget.workspace.save(document, force: force);
      if (mounted) _snack(t.saved(name: baseName(document.path)));
    } on FileChangedOnDisk catch (conflict) {
      if (!mounted) return;
      final choice = await showDialog<_ConflictChoice>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.conflictTitle),
          content: Text(conflict.deleted ? t.conflictDeleted : t.conflictChanged),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.common.cancel)),
            if (!conflict.deleted)
              TextButton(
                onPressed: () => Navigator.pop(context, _ConflictChoice.reload),
                child: Text(t.discardAndReload),
              ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _ConflictChoice.overwrite),
              child: Text(t.overwrite),
            ),
          ],
        ),
      );
      switch (choice) {
        case _ConflictChoice.overwrite:
          await _save(force: true);
        case _ConflictChoice.reload:
          await _reload();
        case null:
          break;
      }
    } on Object catch (error) {
      if (mounted) _snack(t.saveFailed(error: error.toString()));
    }
  }

  Future<void> _reload() async {
    final t = context.t.dock.fileBrowser;
    try {
      await widget.workspace.reload(widget.document);
      _diff = null;
    } on Object catch (error) {
      if (mounted) _snack(t.openFailed(error: error.toString()));
    }
  }

  Future<void> _close() async {
    final document = widget.document;
    if (document.dirty) {
      final t = context.t.dock.fileBrowser;
      final discard = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(t.discardTitle(name: baseName(document.path))),
          content: Text(t.discardBody),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t.common.cancel)),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.discard)),
          ],
        ),
      );
      if (discard != true) return;
    }
    widget.workspace.closeDocument(document);
  }

  void _toggleDiff() {
    setState(() {
      _showDiff = !_showDiff;
      if (_showDiff) _diff = widget.workspace.diff(widget.document.path);
    });
  }

  @override
  void dispose() {
    _find.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.fileBrowser;
    final theme = Theme.of(context);
    final workspace = widget.workspace;
    final document = widget.document;
    final change = workspace.git?.changeOf(document.path);
    final canDiff = change != null && change != GitChange.untracked && change != GitChange.ignored;
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _save,
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _save,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Row(
              children: [
                IconButton(tooltip: t.backToFiles, onPressed: workspace.showBrowser, icon: const Icon(Icons.arrow_back)),
                Expanded(
                  child: Tooltip(
                    message: hostPath(document.path),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: baseName(document.path)),
                          if (document.dirty)
                            TextSpan(text: ' ●', style: TextStyle(color: theme.colorScheme.primary)),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                ),
                if (canDiff)
                  IconButton(
                    tooltip: _showDiff ? t.showFile : t.showDiff,
                    isSelected: _showDiff,
                    onPressed: _toggleDiff,
                    icon: const Icon(Icons.difference_outlined),
                    selectedIcon: const Icon(Icons.difference),
                  ),
                if (!document.readOnly)
                  IconButton(
                    tooltip: t.save,
                    onPressed: document.dirty && !document.saving ? _save : null,
                    icon: document.saving
                        ? const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.save_outlined),
                  ),
                PopupMenuButton<_EditorAction>(
                  tooltip: t.more,
                  onSelected: (action) async {
                    switch (action) {
                      case _EditorAction.find:
                        _find.findMode();
                      case _EditorAction.reload:
                        await _reload();
                      case _EditorAction.copyPath:
                        await Clipboard.setData(ClipboardData(text: hostPath(document.path)));
                        if (context.mounted) _snack(context.t.common.copied);
                      case _EditorAction.close:
                        await _close();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(value: _EditorAction.find, child: Text(t.find)),
                    PopupMenuItem(value: _EditorAction.reload, child: Text(t.reload)),
                    PopupMenuItem(value: _EditorAction.copyPath, child: Text(t.copyPath)),
                    PopupMenuItem(value: _EditorAction.close, child: Text(context.t.common.close)),
                  ],
                ),
              ],
            ),
          ),
          if (workspace.documents.length > 1) _DocumentStrip(workspace: workspace, current: document),
          if (document.readOnlyReason case final reason?)
            Material(
              color: theme.colorScheme.secondaryContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Text(
                  switch (reason) {
                    ReadOnlyReason.tooLarge => t.tooLarge(mb: maxEditableBytes ~/ (1024 * 1024)),
                    ReadOnlyReason.binary => t.binary,
                    ReadOnlyReason.notUtf8 => t.notUtf8,
                  },
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                ),
              ),
            ),
          const Divider(height: 1),
          Expanded(
            child: _showDiff
                ? _GitDiff(diff: _diff!, onRetry: () => setState(() => _diff = workspace.diff(document.path)))
                : document.readOnlyReason == ReadOnlyReason.binary
                ? const SizedBox.shrink()
                : _Editor(document: document, find: _find, scroll: _scroll),
          ),
        ],
      ),
    );
  }
}

enum _ConflictChoice { overwrite, reload }

enum _EditorAction { find, reload, copyPath, close }

class _Editor extends StatelessWidget {
  const _Editor({required this.document, required this.find, required this.scroll});

  final FileDocument document;
  final CodeFindController find;
  final CodeScrollController scroll;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final code = codeTextStyle(theme);
    final language = languageFor(baseName(document.path));
    final mode = language == null ? null : modeFor(language);
    final colors = {
      ...highlightTheme(theme.brightness),
      'root': TextStyle(color: scheme.onSurface),
    };
    return CodeEditor(
      controller: document.controller,
      findController: find,
      scrollController: scroll,
      readOnly: document.readOnly,
      showCursorWhenReadOnly: true,
      wordWrap: false,
      maxLengthSingleLineRendering: 4000,
      style: CodeEditorStyle(
        fontSize: code.fontSize,
        fontFamily: code.fontFamily,
        fontHeight: 1.35,
        textColor: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerLowest,
        selectionColor: scheme.primary.withValues(alpha: 0.25),
        highlightColor: scheme.tertiary.withValues(alpha: 0.25),
        cursorColor: scheme.primary,
        cursorLineColor: scheme.surfaceContainerHigh.withValues(alpha: 0.6),
        codeTheme: CodeHighlightTheme(
          languages: {if (mode != null) language!: CodeHighlightThemeMode(mode: mode)},
          theme: colors,
        ),
      ),
      indicatorBuilder: (context, editingController, chunkController, notifier) => Row(
        children: [
          DefaultCodeLineNumber(
            controller: editingController,
            notifier: notifier,
            textStyle: code.copyWith(color: scheme.outline, fontSize: (code.fontSize ?? 12) - 1),
            focusedTextStyle: code.copyWith(color: scheme.onSurface, fontSize: (code.fontSize ?? 12) - 1),
          ),
          const SizedBox(width: 6),
        ],
      ),
      findBuilder: (context, controller, readOnly) => _FindPanel(controller: controller, readOnly: readOnly),
    );
  }
}

/// The editor's find (and replace) bar.
class _FindPanel extends StatelessWidget implements PreferredSizeWidget {
  const _FindPanel({required this.controller, required this.readOnly});

  final CodeFindController controller;
  final bool readOnly;

  static const _rowHeight = 40.0;

  @override
  Size get preferredSize {
    final value = controller.value;
    if (value == null) return Size.zero;
    return Size.fromHeight(value.replaceMode && !readOnly ? _rowHeight * 2 : _rowHeight);
  }

  @override
  Widget build(BuildContext context) {
    final value = controller.value;
    if (value == null) return const SizedBox.shrink();
    final t = context.t.dock.fileBrowser;
    final theme = Theme.of(context);
    final result = value.result;
    final count = result == null || result.matches.isEmpty ? t.noMatches : '${result.index + 1}/${result.matches.length}';
    return Material(
      color: theme.colorScheme.surfaceContainer,
      child: Column(
        children: [
          SizedBox(
            height: _rowHeight,
            child: Row(
              children: [
                if (!readOnly)
                  IconButton(
                    tooltip: t.replace,
                    visualDensity: VisualDensity.compact,
                    onPressed: controller.toggleMode,
                    icon: Icon(value.replaceMode ? Icons.expand_more : Icons.chevron_right, size: 18),
                  )
                else
                  const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: controller.findInputController,
                    focusNode: controller.findInputFocusNode,
                    style: theme.textTheme.bodySmall,
                    decoration: InputDecoration(isDense: true, hintText: t.find, border: InputBorder.none),
                    onSubmitted: (_) => controller.nextMatch(),
                  ),
                ),
                Text(count, style: theme.textTheme.labelSmall),
                IconButton(
                  tooltip: t.caseSensitive,
                  visualDensity: VisualDensity.compact,
                  isSelected: value.option.caseSensitive,
                  onPressed: controller.toggleCaseSensitive,
                  icon: const Icon(Icons.format_size, size: 18),
                ),
                IconButton(
                  tooltip: t.previousMatch,
                  visualDensity: VisualDensity.compact,
                  onPressed: controller.previousMatch,
                  icon: const Icon(Icons.keyboard_arrow_up, size: 18),
                ),
                IconButton(
                  tooltip: t.nextMatch,
                  visualDensity: VisualDensity.compact,
                  onPressed: controller.nextMatch,
                  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
                ),
                IconButton(
                  tooltip: context.t.common.close,
                  visualDensity: VisualDensity.compact,
                  onPressed: controller.close,
                  icon: const Icon(Icons.close, size: 18),
                ),
              ],
            ),
          ),
          if (value.replaceMode && !readOnly)
            SizedBox(
              height: _rowHeight,
              child: Row(
                children: [
                  const SizedBox(width: 40),
                  Expanded(
                    child: TextField(
                      controller: controller.replaceInputController,
                      focusNode: controller.replaceInputFocusNode,
                      style: theme.textTheme.bodySmall,
                      decoration: InputDecoration(isDense: true, hintText: t.replace, border: InputBorder.none),
                      onSubmitted: (_) => controller.replaceMatch(),
                    ),
                  ),
                  TextButton(onPressed: controller.replaceMatch, child: Text(t.replace)),
                  TextButton(onPressed: controller.replaceAllMatches, child: Text(t.replaceAll)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Tabs of the open documents.
class _DocumentStrip extends StatelessWidget {
  const _DocumentStrip({required this.workspace, required this.current});

  final FileWorkspace workspace;
  final FileDocument current;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          for (final document in workspace.documents)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: ChoiceChip(
                visualDensity: VisualDensity.compact,
                label: Text(document.dirty ? '${baseName(document.path)} ●' : baseName(document.path)),
                selected: identical(document, current),
                onSelected: (_) => workspace.show(document),
              ),
            ),
        ],
      ),
    );
  }
}

/// Caps the rows a diff builds; [DiffView] lays out every row.
const _maxDiffLines = 4000;

class _GitDiff extends StatelessWidget {
  const _GitDiff({required this.diff, required this.onRetry});

  final Future<String> diff;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.fileBrowser;
    return FutureBuilder<String>(
      future: diff,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.diffFailed(error: snapshot.error.toString()), textAlign: TextAlign.center),
                TextButton(onPressed: onRetry, child: Text(context.t.common.retry)),
              ],
            ),
          );
        }
        final text = snapshot.data;
        if (text == null) return const Center(child: CircularProgressIndicator());
        if (text.trim().isEmpty) return Center(child: Text(t.noChanges));
        final lines = parseUnifiedDiff(text);
        final shown = lines.length > _maxDiffLines ? lines.sublist(0, _maxDiffLines) : lines;
        return SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DiffView(lines: shown),
              if (shown.length < lines.length)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(t.diffTruncated(shown: shown.length, total: lines.length)),
                ),
            ],
          ),
        );
      },
    );
  }
}
