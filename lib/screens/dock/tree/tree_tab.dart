import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/companion.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../../i18n/strings.g.dart';
import '../../../sessions/sessions_provider.dart';
import '../dock_empty_state.dart';
import 'session_tree.dart';

/// The session tree (`/tree`): every branch of the conversation, the current leaf highlighted. Navigate the leaf
/// (optionally summarizing the abandoned branch), label entries, or branch a user message into a new session.
class TreeTab extends StatefulWidget {
  const TreeTab({super.key, required this.session});

  final LiveSession session;

  @override
  State<TreeTab> createState() => _TreeTabState();
}

class _TreeTabState extends State<TreeTab> {
  static const _rowHeight = 30.0;

  SessionTree? _tree;
  List<TreeRow> _rows = const [];
  Object? _error;
  var _loading = false;
  var _reloadAgain = false;
  var _filter = TreeFilter.standard;
  var _query = '';
  final _toggled = <String>{};
  String? _selectedId;
  final _search = TextEditingController();

  /// A navigation with summary in flight; `tree.abort` stops it.
  var _summarizing = false;
  var _busy = false;

  StreamSubscription<SessionView>? _views;
  StreamSubscription<LinkState>? _links;
  List<TranscriptItem>? _seenTranscript;
  String? _seenSessionId;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(TreeTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      _detach();
      _tree = null;
      _rows = const [];
      _toggled.clear();
      _selectedId = null;
      _error = null;
      _attach();
    }
  }

  void _attach() {
    final session = widget.session;
    _seenTranscript = session.view.transcript;
    _seenSessionId = session.view.config.sessionId;
    _views = session.views.listen(_onView);
    _links = session.linkStates.listen((state) {
      if (state is LinkLive && (_tree == null || _error != null)) unawaited(_reload());
    });
    // Not from initState or didUpdateWidget: the reload sets state.
    scheduleMicrotask(() {
      if (mounted) unawaited(_reload());
    });
  }

  void _detach() {
    _debounce?.cancel();
    unawaited(_views?.cancel());
    unawaited(_links?.cancel());
  }

  /// The tree changes when entries are appended or the session is replaced. While a run streams, the transcript
  /// changes per token; reload once it settles.
  void _onView(SessionView view) {
    final changed = !identical(view.transcript, _seenTranscript) || view.config.sessionId != _seenSessionId;
    if (!changed || view.run.running) return;
    _seenTranscript = view.transcript;
    _seenSessionId = view.config.sessionId;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_reload()));
  }

  Future<void> _reload() async {
    if (_loading) {
      _reloadAgain = true;
      return;
    }
    if (widget.session.linkState is! LinkLive) return;
    setState(() => _loading = true);
    final session = widget.session;
    try {
      final result = await session.rpc.getTree();
      if (!mounted || !identical(session, widget.session)) return;
      final tree = SessionTree.decode(result.tree, result.leafId);
      setState(() {
        _tree = tree;
        _error = null;
        _rebuildRows();
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
      if (_reloadAgain) {
        _reloadAgain = false;
        unawaited(_reload());
      }
    }
  }

  void _rebuildRows() {
    _rows = _tree?.rows(filter: _filter, query: _query, toggled: _toggled) ?? const [];
  }

  void _toggle(String id) {
    setState(() {
      if (!_toggled.remove(id)) _toggled.add(id);
      _rebuildRows();
    });
  }

  TreeEntry? get _selected {
    final id = _selectedId;
    if (id == null) return null;
    return _tree?.entries.where((entry) => entry.id == id).firstOrNull;
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _navigate(TreeEntry entry, {bool summarize = false, String? instructions}) async {
    final session = widget.session;
    final sessions = context.read<SessionsProvider>();
    final t = context.t.dock.sessionTree;
    setState(() {
      _busy = true;
      _summarizing = summarize;
    });
    try {
      final result = await session.companion.call('tree.navigate', {
        'entryId': entry.id,
        if (summarize) 'summarize': true,
        if (summarize && instructions != null && instructions.trim().isNotEmpty) 'customInstructions': instructions.trim(),
      });
      if (result case {'cancelled': true, 'aborted': final bool aborted}) {
        if (mounted) _snack(aborted ? t.summaryAborted : t.navigationCancelled);
        return;
      }
      if (result case {'editorText': final String? text, 'editorImages': final List<Object?> images}) {
        final attachments = [
          for (final image in images)
            if (image case {'data': final String data, 'mimeType': final String mimeType})
              RpcImage(data: data, mimeType: mimeType),
        ];
        if ((text != null && text.isNotEmpty) || attachments.isNotEmpty) {
          sessions.setDraft(session, text ?? '', images: attachments);
        }
      }
      await _reload();
    } on CompanionException catch (error) {
      if (mounted) _snack(t.failed(error: error.message));
    } on RpcException catch (error) {
      if (mounted) _snack(t.failed(error: error.toString()));
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _summarizing = false;
        });
      }
    }
  }

  Future<void> _abortSummary() async {
    try {
      await widget.session.companion.call('tree.abort');
    } on CompanionException catch (error) {
      if (mounted) _snack(context.t.dock.sessionTree.failed(error: error.message));
    }
  }

  Future<void> _summarizeDialog(TreeEntry entry) async {
    final instructions = await showDialog<String>(context: context, builder: (_) => const _SummaryDialog());
    if (instructions == null || !mounted) return;
    await _navigate(entry, summarize: true, instructions: instructions);
  }

  Future<void> _labelDialog(TreeEntry entry) async {
    final label = await showDialog<_LabelResult>(
      context: context,
      builder: (_) => _LabelDialog(initial: entry.label),
    );
    if (label == null || !mounted) return;
    final t = context.t.dock.sessionTree;
    try {
      await widget.session.companion.call('tree.label', {'entryId': entry.id, 'label': label.value});
      await _reload();
    } on CompanionException catch (error) {
      if (mounted) _snack(t.failed(error: error.message));
    }
  }

  Future<void> _branch(TreeEntry entry) async {
    final session = widget.session;
    final sessions = context.read<SessionsProvider>();
    final t = context.t.dock.sessionTree;
    setState(() => _busy = true);
    try {
      final result = await session.rpc.branch(entry.id);
      if (result.cancelled) {
        if (mounted) _snack(t.branchCancelled);
        return;
      }
      sessions.setDraft(session, result.text);
      if (mounted) _snack(t.branched);
    } on RpcException catch (error) {
      if (mounted) _snack(t.failed(error: error.toString()));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _rowMenu(TreeRow row, Offset position) async {
    setState(() => _selectedId = row.entry.id);
    final t = context.t.dock.sessionTree;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final action = await showMenu<_TreeAction>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        for (final action in _actionsFor(row.entry))
          PopupMenuItem(value: action, child: Text(_actionLabel(t, action))),
      ],
    );
    if (action != null && mounted) await _run(action, row.entry);
  }

  List<_TreeAction> _actionsFor(TreeEntry entry) => [
    if (entry.id != _tree?.leafId) ...[_TreeAction.navigate, _TreeAction.summarize],
    _TreeAction.label,
    if (entry.kind == TreeEntryKind.user) _TreeAction.branch,
    if (entry.text.isNotEmpty) _TreeAction.copy,
  ];

  String _actionLabel(Translations$dock$sessionTree$en t, _TreeAction action) => switch (action) {
    _TreeAction.navigate => t.navigate,
    _TreeAction.summarize => t.navigateWithSummary,
    _TreeAction.label => t.label,
    _TreeAction.branch => t.branch,
    _TreeAction.copy => t.copyText,
  };

  Future<void> _run(_TreeAction action, TreeEntry entry) async {
    switch (action) {
      case _TreeAction.navigate:
        await _navigate(entry);
      case _TreeAction.summarize:
        await _summarizeDialog(entry);
      case _TreeAction.label:
        await _labelDialog(entry);
      case _TreeAction.branch:
        await _branch(entry);
      case _TreeAction.copy:
        await Clipboard.setData(ClipboardData(text: entry.text));
        if (mounted) _snack(context.t.common.copied);
    }
  }

  @override
  void dispose() {
    _detach();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.sessionTree;
    final theme = Theme.of(context);
    final tree = _tree;
    final selected = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 4, 4),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _search,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 18),
                      hintText: t.search,
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                    onChanged: (value) => setState(() {
                      _query = value;
                      _rebuildRows();
                    }),
                  ),
                ),
              ),
              PopupMenuButton<TreeFilter>(
                tooltip: t.filter,
                icon: Icon(Icons.filter_list, color: _filter == TreeFilter.standard ? null : theme.colorScheme.primary),
                initialValue: _filter,
                onSelected: (filter) => setState(() {
                  _filter = filter;
                  _rebuildRows();
                }),
                itemBuilder: (_) => [
                  for (final filter in TreeFilter.values)
                    CheckedPopupMenuItem(value: filter, checked: filter == _filter, child: Text(_filterLabel(t, filter))),
                ],
              ),
              IconButton(
                tooltip: t.refresh,
                onPressed: _loading ? null : _reload,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_loading) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
        if (_summarizing)
          MaterialBanner(
            content: Text(t.summarizing),
            leading: const SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2)),
            actions: [TextButton(onPressed: _abortSummary, child: Text(t.abort))],
          ),
        Expanded(
          child: switch ((tree, _error)) {
            (null, final Object error) => DockEmptyState(
              icon: Icons.error_outline,
              message: t.loadFailed(error: error.toString()),
              action: TextButton(onPressed: _reload, child: Text(context.t.common.retry)),
            ),
            (null, _) => const Center(child: CircularProgressIndicator()),
            (final SessionTree tree, _) when tree.isEmpty => DockEmptyState(
              icon: Icons.account_tree_outlined,
              message: t.empty,
            ),
            (_, _) when _rows.isEmpty => DockEmptyState(icon: Icons.filter_list_off, message: t.noMatches),
            _ => ListView.builder(
              itemExtent: _rowHeight,
              itemCount: _rows.length,
              itemBuilder: (context, index) {
                final row = _rows[index];
                return _TreeRowTile(
                  key: ValueKey(row.entry.id),
                  row: row,
                  selected: row.entry.id == _selectedId,
                  onTap: () => setState(() => _selectedId = row.entry.id == _selectedId ? null : row.entry.id),
                  onToggle: row.branchHead ? () => _toggle(row.entry.id) : null,
                  onMenu: (position) => _rowMenu(row, position),
                );
              },
            ),
          },
        ),
        if (selected != null) ...[
          const Divider(height: 1),
          _SelectionBar(
            entry: selected,
            busy: _busy,
            actions: _actionsFor(selected),
            label: (action) => _actionLabel(t, action),
            onAction: (action) => _run(action, selected),
          ),
        ],
      ],
    );
  }

  String _filterLabel(Translations$dock$sessionTree$en t, TreeFilter filter) => switch (filter) {
    TreeFilter.standard => t.filterStandard,
    TreeFilter.noTools => t.filterNoTools,
    TreeFilter.userOnly => t.filterUserOnly,
    TreeFilter.labeledOnly => t.filterLabeled,
    TreeFilter.all => t.filterAll,
  };
}

enum _TreeAction { navigate, summarize, label, branch, copy }

class _TreeRowTile extends StatelessWidget {
  const _TreeRowTile({
    super.key,
    required this.row,
    required this.selected,
    required this.onTap,
    required this.onToggle,
    required this.onMenu,
  });

  final TreeRow row;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onToggle;
  final void Function(Offset globalPosition) onMenu;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final entry = row.entry;
    final (icon, color) = _kindIcon(entry.kind, scheme);
    final muted = entry.bookkeeping || entry.kind == TreeEntryKind.toolResult;
    final textStyle = theme.textTheme.bodySmall?.copyWith(
      color: entry.error ? scheme.error : (muted ? scheme.onSurfaceVariant : scheme.onSurface),
      fontWeight: row.isLeaf ? FontWeight.w700 : null,
      fontStyle: entry.text.isEmpty ? FontStyle.italic : null,
    );
    return Material(
      color: selected ? scheme.secondaryContainer : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapUp: (details) => onMenu(details.globalPosition),
        onLongPress: () {
          final box = context.findRenderObject()! as RenderBox;
          onMenu(box.localToGlobal(Offset(box.size.width / 2, box.size.height / 2)));
        },
        child: Row(
          children: [
            Container(width: 3, color: row.onActivePath ? scheme.primary : Colors.transparent),
            SizedBox(width: 4.0 + row.depth * 14),
            SizedBox(
              width: 20,
              child: onToggle == null
                  ? null
                  : InkResponse(
                      onTap: onToggle,
                      radius: 14,
                      child: Icon(row.collapsedCount != null ? Icons.chevron_right : Icons.expand_more, size: 18),
                    ),
            ),
            Icon(icon, size: 15, color: color),
            const SizedBox(width: 6),
            if (entry.label case final label?) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: scheme.tertiaryContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onTertiaryContainer)),
              ),
              const SizedBox(width: 4),
            ],
            Expanded(
              child: Text(_rowText(context, entry), maxLines: 1, overflow: TextOverflow.ellipsis, style: textStyle),
            ),
            if (row.collapsedCount case final hidden?)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Text('+$hidden', style: theme.textTheme.labelSmall?.copyWith(color: scheme.outline)),
              ),
            if (row.isLeaf)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Tooltip(
                  message: context.t.dock.sessionTree.currentLeaf,
                  child: Icon(Icons.my_location, size: 14, color: scheme.primary),
                ),
              ),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }
}

/// A row's text; entries without text of their own describe themselves.
String _rowText(BuildContext context, TreeEntry entry) {
  final t = context.t.dock.sessionTree;
  return switch (entry.kind) {
    TreeEntryKind.assistant when entry.aborted => t.aborted,
    TreeEntryKind.assistant when entry.text.isEmpty => t.noContent,
    TreeEntryKind.compaction => t.compaction(tokens: ((entry.tokensBefore ?? 0) / 1000).round()),
    TreeEntryKind.branchSummary => t.branchSummary(summary: entry.text),
    TreeEntryKind.modelChange => t.model(model: entry.text),
    TreeEntryKind.thinkingChange => t.thinking(level: entry.text),
    TreeEntryKind.label => entry.text.isEmpty ? t.labelCleared : t.labelSet(label: entry.text),
    TreeEntryKind.other when entry.text.isEmpty => '[${entry.type.replaceAll('_', ' ')}]',
    TreeEntryKind.other => '[${entry.type.replaceAll('_', ' ')}] ${entry.text}',
    _ => entry.text,
  };
}

(IconData, Color) _kindIcon(TreeEntryKind kind, ColorScheme scheme) => switch (kind) {
  TreeEntryKind.user => (Icons.person_outline, scheme.primary),
  TreeEntryKind.assistant => (Icons.smart_toy_outlined, scheme.tertiary),
  TreeEntryKind.toolResult => (Icons.build_outlined, scheme.outline),
  TreeEntryKind.bash => (Icons.terminal, scheme.outline),
  TreeEntryKind.python => (Icons.code, scheme.outline),
  TreeEntryKind.custom => (Icons.extension_outlined, scheme.secondary),
  TreeEntryKind.compaction => (Icons.compress, scheme.secondary),
  TreeEntryKind.branchSummary => (Icons.call_split, scheme.secondary),
  TreeEntryKind.modelChange => (Icons.swap_horiz, scheme.outline),
  TreeEntryKind.thinkingChange => (Icons.psychology_outlined, scheme.outline),
  TreeEntryKind.label => (Icons.label_outline, scheme.outline),
  TreeEntryKind.other => (Icons.circle_outlined, scheme.outline),
};

class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.entry,
    required this.busy,
    required this.actions,
    required this.label,
    required this.onAction,
  });

  final TreeEntry entry;
  final bool busy;
  final List<_TreeAction> actions;
  final String Function(_TreeAction action) label;
  final void Function(_TreeAction action) onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _rowText(context, entry),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              for (final action in actions)
                if (action != _TreeAction.copy)
                  FilledButton.tonal(
                    style: FilledButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                    ),
                    onPressed: busy ? null : () => onAction(action),
                    child: Text(label(action)),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SummaryDialog extends StatefulWidget {
  const _SummaryDialog();

  @override
  State<_SummaryDialog> createState() => _SummaryDialogState();
}

class _SummaryDialogState extends State<_SummaryDialog> {
  final _instructions = TextEditingController();

  @override
  void dispose() {
    _instructions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.sessionTree;
    return AlertDialog(
      title: Text(t.summaryTitle),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.summaryBody),
            const SizedBox(height: 12),
            TextField(
              controller: _instructions,
              autofocus: true,
              minLines: 2,
              maxLines: 6,
              decoration: InputDecoration(labelText: t.summaryInstructions, border: const OutlineInputBorder()),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _instructions.text), child: Text(t.summarize)),
      ],
    );
  }
}

/// A label to set; [value] null clears it.
final class _LabelResult {
  const _LabelResult(this.value);

  final String? value;
}

class _LabelDialog extends StatefulWidget {
  const _LabelDialog({required this.initial});

  final String? initial;

  @override
  State<_LabelDialog> createState() => _LabelDialogState();
}

class _LabelDialogState extends State<_LabelDialog> {
  late final _label = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _label.text.trim();
    Navigator.pop(context, _LabelResult(value.isEmpty ? null : value));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.sessionTree;
    return AlertDialog(
      title: Text(t.labelTitle),
      content: SizedBox(
        width: 360,
        child: TextField(
          controller: _label,
          autofocus: true,
          decoration: InputDecoration(labelText: t.labelField, border: const OutlineInputBorder()),
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        if (widget.initial != null)
          TextButton(onPressed: () => Navigator.pop(context, const _LabelResult(null)), child: Text(t.clearLabel)),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.common.cancel)),
        FilledButton(onPressed: _submit, child: Text(context.t.common.save)),
      ],
    );
  }
}
