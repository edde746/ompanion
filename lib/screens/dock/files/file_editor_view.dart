import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/host.dart';
import 'package:re_editor/re_editor.dart';

import '../../../files/file_document.dart';
import '../../../files/file_language.dart';
import '../../../files/file_paths.dart';
import '../../../files/file_workspace.dart';
import '../../../files/git_status.dart';
import '../../../app/theme.dart';
import '../../../i18n/strings.g.dart';
import '../../../widgets/activity_mark.dart';
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
            FilledButton(onPressed: () => Navigator.pop(context, _ConflictChoice.overwrite), child: Text(t.overwrite)),
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
    } on Object catch (error) {
      if (mounted) _snack(t.openFailed(error: error.toString()));
      return;
    }
    // The text came from disk again, so a diff on screen is stale.
    if (!mounted) return;
    setState(() {
      _diff = _showDiff ? widget.workspace.diff(widget.document.path) : null;
    });
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
                IconButton(
                  tooltip: t.backToFiles,
                  onPressed: workspace.showBrowser,
                  icon: const Icon(Symbols.arrow_back),
                ),
                Expanded(
                  child: Tooltip(
                    message: hostPath(document.path),
                    child: Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(text: baseName(document.path)),
                          if (document.dirty)
                            TextSpan(
                              text: ' ●',
                              style: TextStyle(color: theme.colorScheme.onSurfaceVariant),
                            ),
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
                    icon: const Icon(Symbols.difference),
                    selectedIcon: const Icon(Symbols.difference, fill: 1),
                  ),
                if (!document.readOnly)
                  IconButton(
                    tooltip: t.save,
                    onPressed: document.dirty && !document.saving ? _save : null,
                    icon: document.saving ? const ActivityMark(size: 18) : const Icon(Symbols.save),
                  ),
                PopupMenuButton<_EditorAction>(
                  tooltip: t.more,
                  icon: const Icon(Symbols.more_vert),
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
            Container(
              margin: const EdgeInsets.fromLTRB(8, 4, 8, 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: BorderRadius.circular(AppSizes.radius),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Text(switch (reason) {
                  ReadOnlyReason.tooLarge => t.tooLarge(mb: maxEditableBytes ~/ (1024 * 1024)),
                  ReadOnlyReason.binary => t.binary,
                  ReadOnlyReason.notUtf8 => t.notUtf8,
                }, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ),
            ),
          Expanded(
            child: _showDiff
                ? _GitDiff(diff: _diff!, onRetry: () => setState(() => _diff = workspace.diff(document.path)))
                : document.readOnlyReason == ReadOnlyReason.binary
                ? const SizedBox.shrink()
                : _Editor(document: document, find: _find, scroll: _scroll, onSave: _save),
          ),
        ],
      ),
    );
  }
}

enum _ConflictChoice { overwrite, reload }

enum _EditorAction { find, reload, copyPath, close }

class _Editor extends StatelessWidget {
  const _Editor({required this.document, required this.find, required this.scroll, required this.onSave});

  final FileDocument document;
  final CodeFindController find;
  final CodeScrollController scroll;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final code = codeTextStyle(theme);
    final language = languageFor(baseName(document.path));
    final mode = language == null ? null : modeFor(language);
    final colors = {...highlightTheme(theme.brightness), 'root': TextStyle(color: scheme.onSurface)};
    return CodeEditor(
      controller: document.controller,
      findController: find,
      scrollController: scroll,
      readOnly: document.readOnly,
      showCursorWhenReadOnly: true,
      wordWrap: false,
      maxLengthSingleLineRendering: 4000,
      // The editor binds Cmd+S (Ctrl+S elsewhere) itself and consumes it, so the view's own binding never sees it.
      shortcutOverrideActions: {
        CodeShortcutSaveIntent: CallbackAction<CodeShortcutSaveIntent>(
          onInvoke: (_) {
            unawaited(onSave());
            return null;
          },
        ),
      },
      style: CodeEditorStyle(
        fontSize: code.fontSize,
        fontFamily: code.fontFamily,
        fontHeight: 1.35,
        textColor: scheme.onSurface,
        backgroundColor: scheme.surfaceContainerLowest,
        // The editor selects the current find match and paints every match's highlight over the selection, so a
        // strong selection under a faint highlight sets the current match apart from the others.
        selectionColor: scheme.onSurface.withValues(alpha: 0.32),
        highlightColor: scheme.onSurface.withValues(alpha: 0.16),
        cursorColor: scheme.onSurface,
        cursorLineColor: scheme.surfaceContainer,
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
            textStyle: code.copyWith(color: scheme.onSurfaceVariant, fontSize: (code.fontSize ?? 12) - 1),
            focusedTextStyle: code.copyWith(color: scheme.onSurface, fontSize: (code.fontSize ?? 12) - 1),
          ),
          const SizedBox(width: 6),
        ],
      ),
      findBuilder: (context, controller, readOnly) => _FindPanel(controller: controller, readOnly: readOnly),
    );
  }
}

/// The editor's find (and replace) bar. [CodeEditor] stacks it over the text unpositioned, so it must size itself to
/// [preferredSize]: a bar that fills the loose height it gets covers the whole editor.
class _FindPanel extends StatelessWidget implements PreferredSizeWidget {
  const _FindPanel({required this.controller, required this.readOnly});

  final CodeFindController controller;
  final bool readOnly;

  /// A control-height field plus 4 px above and below.
  static const _rowHeight = AppSizes.control + 8;

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
    final count = result == null || result.matches.isEmpty
        ? t.noMatches
        : '${result.index + 1}/${result.matches.length}';
    Widget row(List<Widget> children) => SizedBox(
      height: _rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(children: children),
      ),
    );
    return SizedBox(
      height: preferredSize.height,
      child: Material(
        color: theme.colorScheme.surfaceContainer,
        child: Column(
          children: [
            row([
              if (!readOnly)
                IconButton(
                  tooltip: t.replace,
                  onPressed: controller.toggleMode,
                  icon: Icon(value.replaceMode ? Symbols.expand_more : Symbols.chevron_right, size: 18),
                )
              else
                const SizedBox(width: 4),
              Expanded(
                child: TextField(
                  controller: controller.findInputController,
                  focusNode: controller.findInputFocusNode,
                  style: theme.textTheme.bodyMedium,
                  decoration: InputDecoration(hintText: t.find),
                  onSubmitted: (_) => controller.nextMatch(),
                ),
              ),
              const SizedBox(width: AppSizes.gap),
              Text(count, style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              IconButton(
                tooltip: t.caseSensitive,
                isSelected: value.option.caseSensitive,
                onPressed: controller.toggleCaseSensitive,
                icon: const Icon(Symbols.format_size, size: 18),
              ),
              IconButton(
                tooltip: t.previousMatch,
                onPressed: controller.previousMatch,
                icon: const Icon(Symbols.keyboard_arrow_up, size: 18),
              ),
              IconButton(
                tooltip: t.nextMatch,
                onPressed: controller.nextMatch,
                icon: const Icon(Symbols.keyboard_arrow_down, size: 18),
              ),
              IconButton(
                tooltip: context.t.common.close,
                onPressed: controller.close,
                icon: const Icon(Symbols.close, size: 18),
              ),
            ]),
            if (value.replaceMode && !readOnly)
              row([
                const SizedBox(width: 40),
                Expanded(
                  child: TextField(
                    controller: controller.replaceInputController,
                    focusNode: controller.replaceInputFocusNode,
                    style: theme.textTheme.bodyMedium,
                    decoration: InputDecoration(hintText: t.replace),
                    onSubmitted: (_) => controller.replaceMatch(),
                  ),
                ),
                const SizedBox(width: AppSizes.gap),
                FilledButton.tonal(onPressed: controller.replaceMatch, child: Text(t.replace)),
                const SizedBox(width: AppSizes.gap),
                FilledButton.tonal(onPressed: controller.replaceAllMatches, child: Text(t.replaceAll)),
              ]),
          ],
        ),
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
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: AppSizes.control + 8,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        children: [
          for (final document in workspace.documents)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: TextButton(
                style: TextButton.styleFrom(
                  shape: const StadiumBorder(),
                  backgroundColor: identical(document, current) ? scheme.surfaceContainerHighest : null,
                  foregroundColor: identical(document, current) ? scheme.onSurface : scheme.onSurfaceVariant,
                ),
                onPressed: () => workspace.show(document),
                child: Text(document.dirty ? '${baseName(document.path)} ●' : baseName(document.path)),
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
        if (text == null) return const Center(child: ActivityMark(size: 20));
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
