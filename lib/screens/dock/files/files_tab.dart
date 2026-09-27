import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

import '../../../app/theme.dart';
import '../../../files/file_paths.dart';
import '../../../files/file_workspace.dart';
import '../../../files/git_status.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/machine.dart';
import '../../../sessions/sessions_provider.dart';
import '../../../utils/byte_size.dart';
import '../../../widgets/activity_mark.dart';
import '../../../widgets/labeled_field.dart';
import '../dock_controller.dart';
import '../machine_access.dart';
import 'file_editor_view.dart';

/// Files of the machine, rooted at the session's directory: a lazy tree with breadcrumbs, and an editor for the
/// files opened from it or from the transcript.
class FilesTab extends StatefulWidget {
  const FilesTab({super.key, required this.machine, required this.session});

  final Machine machine;
  final LiveSession? session;

  @override
  State<FilesTab> createState() => _FilesTabState();
}

class _FilesTabState extends State<FilesTab> {
  late final DockController _dock = context.read<DockController>();
  late FileWorkspace _workspace;

  @override
  void initState() {
    super.initState();
    _bind();
    _dock.addListener(_onDockRequest);
    _onDockRequest();
  }

  @override
  void didUpdateWidget(FilesTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.machine.id != widget.machine.id || !identical(oldWidget.session, widget.session)) _bind();
  }

  void _bind() {
    final sessions = context.read<SessionsProvider>();
    final machine = widget.machine;
    _workspace = _dock.files(machine.id)..connect = () => machineAccess(sessions.runtimeFor(machine));
    unawaited(_workspace.follow(widget.session?.cwd));
  }

  void _onDockRequest() {
    final request = _dock.takeFileRequest();
    if (request == null) return;
    unawaited(_open(_workspace.resolve(request.path, cwd: widget.session?.cwd), line: request.line));
  }

  Future<void> _open(String path, {int? line}) async {
    try {
      await _workspace.open(path, line: line);
    } on Object catch (error) {
      if (mounted) _snack(context.t.dock.fileBrowser.openFailed(error: error.toString()));
    }
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _dock.removeListener(_onDockRequest);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _workspace,
      builder: (context, _) {
        final document = _workspace.current;
        if (document != null) {
          return FileEditorView(key: ObjectKey(document), workspace: _workspace, document: document);
        }
        return _Browser(workspace: _workspace, onOpen: _open, onSnack: _snack);
      },
    );
  }
}

class _Browser extends StatelessWidget {
  const _Browser({required this.workspace, required this.onOpen, required this.onSnack});

  final FileWorkspace workspace;
  final Future<void> Function(String path, {int? line}) onOpen;
  final void Function(String message) onSnack;

  static const _rowHeight = AppSizes.rowHeight;

  Future<void> _create(BuildContext context, String dir, {required bool folder}) async {
    final t = context.t.dock.fileBrowser;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: folder ? t.newFolder : t.newFile, action: t.create),
    );
    if (name == null) return;
    try {
      if (folder) {
        await workspace.createFolder(dir, name);
      } else {
        await workspace.createFile(dir, name);
      }
    } on HostFileExists {
      onSnack(t.exists(name: name));
    } on Object catch (error) {
      onSnack(t.failed(error: error.toString()));
    }
  }

  Future<void> _rename(BuildContext context, String path) async {
    final t = context.t.dock.fileBrowser;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => _NameDialog(title: t.rename, action: t.rename, initial: baseName(path)),
    );
    if (name == null || name == baseName(path)) return;
    try {
      await workspace.rename(path, name);
    } on HostFileExists {
      onSnack(t.exists(name: name));
    } on Object catch (error) {
      onSnack(t.failed(error: error.toString()));
    }
  }

  Future<void> _delete(BuildContext context, EntryRow row) async {
    final t = context.t.dock.fileBrowser;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.deleteTitle(name: row.entry.name)),
        content: Text(row.isLink ? t.deleteLinkBody : (row.isDirectory ? t.deleteFolderBody : t.deleteFileBody)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(context.t.common.delete)),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await workspace.delete(row.path);
    } on Object catch (error) {
      onSnack(t.failed(error: error.toString()));
    }
  }

  Future<void> _menu(BuildContext context, EntryRow row, Offset position) async {
    final t = context.t.dock.fileBrowser;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final dir = row.isDirectory ? row.path : parentPath(row.path);
    final action = await showMenu<_EntryAction>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: _EntryAction.open, child: Text(row.isDirectory ? t.browseHere : t.open)),
        PopupMenuItem(value: _EntryAction.newFile, child: Text(t.newFile)),
        PopupMenuItem(value: _EntryAction.newFolder, child: Text(t.newFolder)),
        PopupMenuItem(value: _EntryAction.rename, child: Text(t.rename)),
        PopupMenuItem(value: _EntryAction.copyPath, child: Text(t.copyPath)),
        PopupMenuItem(value: _EntryAction.delete, child: Text(context.t.common.delete)),
      ],
    );
    if (action == null || !context.mounted) return;
    switch (action) {
      case _EntryAction.open:
        if (row.isDirectory) {
          await workspace.openDir(row.path);
        } else {
          await onOpen(row.path);
        }
      case _EntryAction.newFile:
        await _create(context, dir, folder: false);
      case _EntryAction.newFolder:
        await _create(context, dir, folder: true);
      case _EntryAction.rename:
        await _rename(context, row.path);
      case _EntryAction.copyPath:
        await Clipboard.setData(ClipboardData(text: hostPath(row.path)));
        if (context.mounted) onSnack(context.t.common.copied);
      case _EntryAction.delete:
        await _delete(context, row);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.fileBrowser;
    final theme = Theme.of(context);
    final root = workspace.root;
    if (root == null) return const Center(child: ActivityMark(size: 20));
    final rows = workspace.rows();
    final documents = workspace.documents;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Breadcrumbs(path: root, onOpen: workspace.openDir),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              IconButton(
                tooltip: t.up,
                onPressed: isRootPath(root) ? null : () => workspace.openDir(parentPath(root)),
                icon: const Icon(Symbols.arrow_upward, size: 20),
              ),
              IconButton(tooltip: t.refresh, onPressed: workspace.refresh, icon: const Icon(Symbols.refresh, size: 20)),
              IconButton(
                tooltip: t.newFile,
                onPressed: () => _create(context, root, folder: false),
                icon: const Icon(Symbols.note_add, size: 20),
              ),
              IconButton(
                tooltip: t.newFolder,
                onPressed: () => _create(context, root, folder: true),
                icon: const Icon(Symbols.create_new_folder, size: 20),
              ),
              const Spacer(),
              if (documents.isNotEmpty)
                TextButton.icon(
                  onPressed: () => workspace.show(documents.last),
                  icon: const Icon(Symbols.description, size: 18),
                  label: Text(t.openDocuments(n: documents.length)),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemExtent: _rowHeight,
            itemCount: rows.length,
            itemBuilder: (context, index) => switch (rows[index]) {
              final EntryRow row => _EntryTile(
                key: ValueKey(row.path),
                row: row,
                change: workspace.git?.changeOf(row.path),
                dirty: row.isDirectory && (workspace.git?.dirty.contains(normalizePath(row.path)) ?? false),
                onTap: () => row.isDirectory ? workspace.toggle(row.path) : onOpen(row.path),
                onDoubleTap: row.isDirectory ? () => workspace.openDir(row.path) : null,
                onMenu: (position) => _menu(context, row, position),
              ),
              LoadingRow(:final depth) => _StatusTile(depth: depth, child: const ActivityMark()),
              EmptyRow(:final depth) => _StatusTile(
                depth: depth,
                child: Text(
                  t.emptyFolder,
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              FailedRow(:final depth, :final dir, :final error) => _StatusTile(
                depth: depth,
                child: Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: error.toString(),
                        child: Text(
                          t.listFailed(error: error.toString()),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).error),
                        ),
                      ),
                    ),
                    TextButton(onPressed: () => workspace.reloadDir(dir), child: Text(context.t.common.retry)),
                  ],
                ),
              ),
            },
          ),
        ),
      ],
    );
  }
}

enum _EntryAction { open, newFile, newFolder, rename, copyPath, delete }

class _Breadcrumbs extends StatelessWidget {
  const _Breadcrumbs({required this.path, required this.onOpen});

  final String path;
  final Future<void> Function(String dir) onOpen;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final crumbs = breadcrumbs(path);
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        reverse: true,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: crumbs.length,
        separatorBuilder: (_, _) => Icon(Symbols.chevron_right, size: 16, color: theme.colorScheme.onSurfaceVariant),
        itemBuilder: (context, index) {
          // Reversed so the deepest directory stays in view.
          final crumb = crumbs[crumbs.length - 1 - index];
          final last = index == 0;
          return Center(
            child: InkWell(
              borderRadius: BorderRadius.circular(4),
              onTap: last ? null : () => onOpen(crumb.path),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Text(
                  crumb.label,
                  style: last
                      ? theme.textTheme.labelLarge
                      : theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    super.key,
    required this.row,
    required this.change,
    required this.dirty,
    required this.onTap,
    required this.onDoubleTap,
    required this.onMenu,
  });

  final EntryRow row;
  final GitChange? change;
  final bool dirty;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final void Function(Offset globalPosition) onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final name = row.entry.name;
    final hidden = name.startsWith('.');
    final badge = change == null ? null : _badge(change!, scheme, AppColors.of(context));
    return InkWell(
      onTap: onTap,
      onDoubleTap: onDoubleTap,
      onSecondaryTapUp: (details) => onMenu(details.globalPosition),
      onLongPress: () {
        final box = context.findRenderObject()! as RenderBox;
        onMenu(box.localToGlobal(Offset(box.size.width / 2, box.size.height / 2)));
      },
      child: Padding(
        padding: EdgeInsets.only(left: 8.0 + row.depth * 16, right: 8),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: row.isDirectory
                  ? Icon(
                      row.expanded ? Symbols.expand_more : Symbols.chevron_right,
                      size: 18,
                      color: scheme.onSurfaceVariant,
                    )
                  : null,
            ),
            if (row.isLink)
              Tooltip(
                message: context.t.dock.fileBrowser.link,
                child: Icon(Symbols.link, size: 16, color: scheme.onSurfaceVariant),
              )
            else
              Icon(
                row.isDirectory ? (row.expanded ? Symbols.folder_open : Symbols.folder) : _fileIcon(name),
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: badge?.$2 ?? (hidden ? scheme.onSurfaceVariant : scheme.onSurface),
                ),
              ),
            ),
            if (badge != null)
              Tooltip(
                message: _changeLabel(context, change!),
                child: Text(badge.$1, style: theme.textTheme.labelSmall?.copyWith(color: badge.$2)),
              )
            else if (dirty)
              Icon(Symbols.circle, size: 6, color: AppColors.of(context).warning, fill: 1)
            else if (!row.isDirectory && !row.isLink)
              Text(
                formatBytes(row.entry.stat.size),
                style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}

(String, Color) _badge(GitChange change, ColorScheme scheme, AppColors colors) => switch (change) {
  GitChange.modified => ('M', colors.warning),
  GitChange.added => ('A', colors.success),
  GitChange.deleted => ('D', colors.error),
  GitChange.renamed => ('R', colors.success),
  GitChange.copied => ('C', colors.success),
  GitChange.typeChanged => ('T', colors.warning),
  GitChange.untracked => ('U', colors.success),
  GitChange.ignored => ('I', scheme.onSurfaceVariant),
  GitChange.conflicted => ('!', colors.error),
};

String _changeLabel(BuildContext context, GitChange change) {
  final t = context.t.dock.fileBrowser.git;
  return switch (change) {
    GitChange.modified => t.modified,
    GitChange.added => t.added,
    GitChange.deleted => t.deleted,
    GitChange.renamed => t.renamed,
    GitChange.copied => t.copied,
    GitChange.typeChanged => t.typeChanged,
    GitChange.untracked => t.untracked,
    GitChange.ignored => t.ignored,
    GitChange.conflicted => t.conflicted,
  };
}

IconData _fileIcon(String name) => switch (extensionOf(name)) {
  'md' || 'txt' || 'rst' => Symbols.article,
  'png' || 'jpg' || 'jpeg' || 'gif' || 'webp' || 'svg' || 'ico' => Symbols.image,
  'json' || 'yaml' || 'yml' || 'toml' || 'ini' || 'lock' => Symbols.data_object,
  'zip' || 'gz' || 'tar' || 'tgz' || 'xz' || '7z' => Symbols.archive,
  _ => Symbols.draft,
};

class _StatusTile extends StatelessWidget {
  const _StatusTile({required this.depth, required this.child});

  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(left: 32.0 + depth * 16, right: 8),
    child: Align(alignment: Alignment.centerLeft, child: child),
  );
}

class _NameDialog extends StatefulWidget {
  const _NameDialog({required this.title, required this.action, this.initial});

  final String title;
  final String action;
  final String? initial;

  @override
  State<_NameDialog> createState() => _NameDialogState();
}

class _NameDialogState extends State<_NameDialog> {
  late final _name = TextEditingController(text: widget.initial);
  NameProblem? _problem;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) {
      // Select the stem, as file managers do, so typing replaces the name and keeps the extension.
      final dot = initial.lastIndexOf('.');
      _name.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : initial.length);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final problem = checkName(name);
    if (problem != null) {
      setState(() => _problem = problem);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.fileBrowser;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: LabeledField(
          label: t.name,
          child: TextField(
            controller: _name,
            autofocus: true,
            decoration: InputDecoration(
              errorText: switch (_problem) {
                null => null,
                NameProblem.empty => context.t.common.required,
                NameProblem.reserved => t.nameReserved,
                NameProblem.separator => t.nameSeparator,
              },
            ),
            onSubmitted: (_) => _submit(),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.common.cancel)),
        FilledButton(onPressed: _submit, child: Text(widget.action)),
      ],
    );
  }
}
