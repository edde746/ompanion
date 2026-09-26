import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../config/accounts.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/sessions_provider.dart';
import '../../widgets/labeled_field.dart';
import '../config/model_picker.dart';
import '../machines/connect_dialogs.dart';
import 'machine_sessions.dart';

/// Asks for a working directory on [machine] (recent project directories, a typed path, or a folder picked on
/// the machine) and an optional model, opens a new session there and shows it.
Future<void> showNewSessionDialog(BuildContext context, Machine machine, {String? cwd}) async {
  final shell = context.read<ShellProvider>();
  final session = await showDialog<LiveSession>(
    context: context,
    builder: (_) => _NewSessionDialog(machine: machine, initialCwd: cwd),
  );
  if (session != null) shell.select(const SessionSelection());
}

class _NewSessionDialog extends StatefulWidget {
  const _NewSessionDialog({required this.machine, this.initialCwd});

  final Machine machine;
  final String? initialCwd;

  @override
  State<_NewSessionDialog> createState() => _NewSessionDialogState();
}

class _NewSessionDialogState extends State<_NewSessionDialog> {
  late final TextEditingController _cwd = TextEditingController(text: widget.initialCwd ?? '');

  /// The chosen model: [selector] (`provider/id[:thinking]`) is what omp gets, [name] (the model's name and
  /// provider) is what the field shows. Null leaves omp on its configured default.
  ({String selector, String name})? _model;
  HostProbe? _probe;
  bool _connecting = true;
  bool _loadingModels = false;
  bool _creating = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // _connect reads translations, which initState may not.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_connect());
    });
  }

  @override
  void dispose() {
    _cwd.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final runtime = context.read<SessionsProvider>().runtimeFor(widget.machine);
    final t = context.t;
    try {
      final probe = switch (runtime.status) {
        MachineOnline(:final probe) => probe,
        // omp may have been installed by hand since the probe.
        MachineNeedsOmp() => await runtime.reprobe(),
        _ => await runtime.connectAndProbe(),
      };
      if (!mounted) return;
      setState(() {
        _probe = probe;
        _connecting = false;
        if (runtime.status case MachineNeedsOmp(:final reason)) _error = t.sessions.needsOmp(reason: reason);
      });
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _connecting = false;
          _error = describeConnectError(t, error);
        });
      }
    }
  }

  /// [path] with a leading `~` expanded to the machine's home.
  String _expand(String path) {
    final home = _probe?.home;
    if (home == null) return path;
    if (path == '~') return home;
    if (path.startsWith('~/') || path.startsWith(r'~\')) return '$home${path.substring(1)}';
    return path;
  }

  Future<void> _create() async {
    final t = context.t;
    final sessions = context.read<SessionsProvider>();
    final runtime = sessions.runtimeFor(widget.machine);
    final cwd = _expand(_cwd.text.trim());
    if (cwd.isEmpty) {
      setState(() => _error = t.sessions.directoryRequired);
      return;
    }
    setState(() {
      _creating = true;
      _error = null;
    });
    try {
      final files = await runtime.link.files();
      final HostFileStat? stat;
      try {
        stat = await files.stat(toSftpPath(cwd));
      } finally {
        await files.close();
      }
      if (stat == null || !stat.isDirectory) {
        if (mounted) {
          setState(() {
            _creating = false;
            _error = t.sessions.notADirectory(path: cwd, machine: widget.machine.name);
          });
        }
        return;
      }
      final session = await sessions.open(widget.machine, NewSession(cwd, model: _model?.selector));
      if (mounted) Navigator.pop(context, session);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _creating = false;
          _error = describeConnectError(t, error);
        });
      }
    }
  }

  /// Opens the machine's model picker. The machine's control process may have to start first; a failure leaves
  /// the form usable and Start on omp's default model.
  Future<void> _pickModel() async {
    final t = context.t;
    final sessions = context.read<SessionsProvider>();
    setState(() {
      _loadingModels = true;
      _error = null;
    });
    final List<RpcModel> models;
    try {
      final control = await sessions.control(widget.machine);
      models = await sessions.models(widget.machine, control.rpc);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _loadingModels = false;
          _error = t.chat.modelsFailed(error: describeConnectError(t, error));
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => _loadingModels = false);
    final selector = await pickModel(context, models: models, title: t.sessions.modelPick, current: _model?.selector);
    if (!mounted || selector == null) return;
    setState(() => _model = (selector: selector, name: _modelName(models, selector)));
  }

  /// [selector] as the picker lists it: the model's name and provider, or the selector itself for a typed
  /// selector omp does not list here.
  static String _modelName(List<RpcModel> models, String selector) {
    final id = splitSelector(selector).model;
    for (final model in models) {
      if ('${model.provider}/${model.id}' == id) return '${model.name} · ${model.provider}';
    }
    return selector;
  }

  Future<void> _browse() async {
    final runtime = context.read<SessionsProvider>().runtimeFor(widget.machine);
    final start = _expand(_cwd.text.trim());
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _DirectoryPicker(runtime: runtime, start: start.isEmpty ? null : start),
    );
    if (picked != null) _setCwd(picked);
  }

  /// Puts [path] in the directory field with the caret at its end, ready to type a subdirectory.
  void _setCwd(String path) => _cwd.value = TextEditingValue(
    text: path,
    selection: TextSelection.collapsed(offset: path.length),
  );

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final listing = context.watch<SessionsProvider>().listingOf(widget.machine);
    final recent = <String>[];
    for (final summary in listing.sessions) {
      final cwd = summary.cwd;
      if (cwd != null && !recent.contains(cwd)) recent.add(cwd);
      if (recent.length == 8) break;
    }
    final ready = !_connecting && _probe != null && !_creating;
    final error = _error;
    return AlertDialog(
      title: Text(t.sessions.newSessionOn(machine: widget.machine.name)),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_connecting) const LinearProgressIndicator(),
            LabeledField(
              label: t.sessions.directory,
              child: TextField(
                key: const ValueKey('new-session-cwd'),
                controller: _cwd,
                autofocus: true,
                // Desktop fields select everything when the focus comes back from the directory picker; a typed key
                // would then replace the picked path.
                selectAllOnFocus: false,
                decoration: InputDecoration(
                  hintText: t.sessions.directoryHint,
                  suffixIcon: IconButton(
                    tooltip: t.sessions.browse,
                    icon: const Icon(Icons.folder_open),
                    onPressed: _probe == null ? null : () => unawaited(_browse()),
                  ),
                ),
                onSubmitted: ready ? (_) => unawaited(_create()) : null,
              ),
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 12),
              LabeledField(
                label: t.sessions.recentDirectories,
                child: ConstrainedBox(
                  // Five rows at most; a longer list scrolls, so the dialog keeps one height.
                  constraints: BoxConstraints(
                    maxHeight: (sidebarTouch(context) ? AppSizes.rowHeightTouch : AppSizes.rowHeight) * 5,
                  ),
                  child: ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _cwd,
                    builder: (context, value, _) {
                      final current = _expand(value.text.trim());
                      return ListView.builder(
                        key: const ValueKey('new-session-recent'),
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: recent.length,
                        itemBuilder: (context, index) {
                          final cwd = recent[index];
                          return _RecentProject(
                            key: ValueKey('new-session-recent-$cwd'),
                            path: cwd,
                            home: _probe?.home,
                            selected: cwd == current,
                            onTap: () => _setCwd(cwd),
                          );
                        },
                      );
                    },
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            LabeledField(
              label: t.sessions.model,
              child: Row(
                children: [
                  Expanded(
                    child: _ModelField(
                      label: _model?.name ?? t.sessions.modelDefault,
                      tooltip: _model?.selector,
                      busy: _loadingModels,
                      onPressed: _loadingModels || _probe == null ? null : () => unawaited(_pickModel()),
                    ),
                  ),
                  if (_model != null) ...[
                    const SizedBox(width: AppSizes.gap),
                    // The same clear control the roles page uses to drop an assignment.
                    IconButton(
                      key: const ValueKey('new-session-model-default'),
                      tooltip: t.sessions.modelUseDefault,
                      color: theme.colorScheme.onSurface,
                      onPressed: () => setState(() => _model = null),
                      icon: const Icon(Icons.clear, size: 18),
                    ),
                  ],
                ],
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error, style: TextStyle(color: AppColors.of(context).error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _creating ? null : () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(
          key: const ValueKey('new-session-create'),
          onPressed: ready ? () => unawaited(_create()) : null,
          child: _creating
              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
              : Text(t.sessions.create),
        ),
      ],
    );
  }
}

/// One recent project directory: a dense row that puts its path in the directory field, [selected] when it is
/// the one the field holds. The full path is the row's tooltip.
class _RecentProject extends StatelessWidget {
  const _RecentProject({
    super.key,
    required this.path,
    required this.home,
    required this.selected,
    required this.onTap,
  });

  final String path;
  final String? home;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = shortPath(path, home);
    final cut = shown.lastIndexOf(RegExp(r'[/\\]'));
    // Only the directories above the last segment are cut away, so the segment that tells two long `.cache`
    // paths apart stays readable.
    final head = cut < 0 ? '' : shown.substring(0, cut + 1);
    final tail = cut < 0 ? shown : shown.substring(cut + 1);
    final style = theme.textTheme.bodyMedium;
    return SidebarRow(
      selected: selected,
      onTap: onTap,
      builder: (context, _) => Tooltip(
        message: path,
        child: Row(
          children: [
            Icon(Icons.folder_outlined, size: 16, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 8),
            if (head.isNotEmpty)
              Flexible(
                child: Text(head, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
              ),
            Text(tail, maxLines: 1, style: style),
          ],
        ),
      ),
    );
  }
}

/// The model form field: a flat control showing the chosen model and opening the model picker, with a spinner
/// while the machine's models load.
class _ModelField extends StatelessWidget {
  const _ModelField({required this.label, required this.tooltip, required this.busy, required this.onPressed});

  final String label;
  final String? tooltip;
  final bool busy;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final button = FilledButton.tonal(
      key: const ValueKey('new-session-model'),
      onPressed: busy ? null : onPressed,
      style: const ButtonStyle(
        padding: WidgetStatePropertyAll(EdgeInsetsDirectional.only(start: 12, end: 8)),
        alignment: AlignmentDirectional.centerStart,
      ),
      child: Row(
        children: [
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 4),
          if (busy)
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(Icons.expand_more, size: 18, color: scheme.onSurfaceVariant),
        ],
      ),
    );
    final tooltip = this.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// Browses directories on the machine over its file access (SFTP or local files) and pops the chosen one as a
/// host-native path.
class _DirectoryPicker extends StatefulWidget {
  const _DirectoryPicker({required this.runtime, this.start});

  final MachineRuntime runtime;
  final String? start;

  @override
  State<_DirectoryPicker> createState() => _DirectoryPickerState();
}

class _DirectoryPickerState extends State<_DirectoryPicker> {
  HostFiles? _files;

  /// SFTP path space.
  String? _path;
  List<String>? _entries;
  bool _showHidden = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_open());
  }

  @override
  void dispose() {
    unawaited(_files?.close());
    super.dispose();
  }

  Future<void> _open() async {
    try {
      final files = await widget.runtime.link.files();
      // The picker closed while the channel opened.
      if (!mounted) {
        unawaited(files.close());
        return;
      }
      _files = files;
      final start = widget.start;
      if (start != null) {
        final stat = await files.stat(toSftpPath(start));
        if (stat != null && stat.isDirectory) {
          await _list(toSftpPath(start));
          return;
        }
      }
      await _list(await files.home());
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _list(String path) async {
    final files = _files;
    if (files == null) return;
    setState(() {
      _entries = null;
      _error = null;
    });
    try {
      final entries = await files.list(path);
      final directories = <String>[];
      for (final entry in entries) {
        if (entry.name == '.' || entry.name == '..') continue;
        // Listings describe links themselves; one that leads to a directory is offered like it.
        final stat = entry.stat.isLink ? await files.stat(_join(path, entry.name)) : entry.stat;
        if (stat != null && stat.isDirectory) directories.add(entry.name);
      }
      directories.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      if (mounted) {
        setState(() {
          _path = path;
          _entries = directories;
        });
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  String _join(String dir, String name) => dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  String? _parent(String path) {
    final trimmed = path.length > 1 && path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final index = trimmed.lastIndexOf('/');
    if (index < 0 || trimmed == '/') return null;
    final parent = index == 0 ? '/' : trimmed.substring(0, index);
    // `/C:` is a Windows drive root; its parent lists nothing useful.
    return RegExp(r'^/[A-Za-z]:$').hasMatch(trimmed) ? null : parent;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final path = _path;
    final entries = _entries;
    final error = _error;
    final parent = path == null ? null : _parent(path);
    final shown = entries == null
        ? null
        : [
            for (final name in entries)
              if (_showHidden || !name.startsWith('.')) name,
          ];
    return AlertDialog(
      title: Text(t.sessions.browseTitle),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: t.sessions.up,
                  icon: const Icon(Icons.arrow_upward),
                  onPressed: parent == null ? null : () => unawaited(_list(parent)),
                ),
                Expanded(child: Text(path == null ? '' : hostPath(path), maxLines: 2, overflow: TextOverflow.ellipsis)),
                IconButton(
                  tooltip: t.sessions.showHidden,
                  isSelected: _showHidden,
                  icon: const Icon(Icons.visibility_off_outlined),
                  selectedIcon: const Icon(Icons.visibility_outlined),
                  onPressed: () => setState(() => _showHidden = !_showHidden),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Expanded(
              child: error != null
                  ? Center(child: Text(error))
                  : shown == null
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        for (final name in shown)
                          ListTile(
                            dense: true,
                            leading: const Icon(Icons.folder_outlined),
                            title: Text(name),
                            onTap: () => unawaited(_list(_join(path!, name))),
                          ),
                      ],
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(
          onPressed: path == null ? null : () => Navigator.pop(context, hostPath(path)),
          child: Text(t.sessions.chooseDirectory),
        ),
      ],
    );
  }
}
