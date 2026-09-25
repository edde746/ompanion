import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/shell_provider.dart';
import '../../sessions/sessions_provider.dart';
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
  final _model = TextEditingController();
  HostProbe? _probe;
  bool _connecting = true;
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
    _model.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final runtime = context.read<SessionsProvider>().runtimeFor(widget.machine);
    final t = context.t;
    try {
      final probe = switch (runtime.status) {
        MachineOnline(:final probe) => probe,
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
      final model = _model.text.trim();
      final session = await sessions.open(widget.machine, NewSession(cwd, model: model.isEmpty ? null : model));
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

  Future<void> _browse() async {
    final runtime = context.read<SessionsProvider>().runtimeFor(widget.machine);
    final start = _expand(_cwd.text.trim());
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => _DirectoryPicker(runtime: runtime, start: start.isEmpty ? null : start),
    );
    if (picked != null) _cwd.text = picked;
  }

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
            TextField(
              key: const ValueKey('new-session-cwd'),
              controller: _cwd,
              autofocus: true,
              decoration: InputDecoration(
                labelText: t.sessions.directory,
                hintText: t.sessions.directoryHint,
                suffixIcon: IconButton(
                  tooltip: t.sessions.browse,
                  icon: const Icon(Icons.folder_open),
                  onPressed: _probe == null ? null : () => unawaited(_browse()),
                ),
              ),
              onSubmitted: ready ? (_) => unawaited(_create()) : null,
            ),
            if (recent.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(t.sessions.recentDirectories, style: theme.textTheme.labelMedium),
              const SizedBox(height: 4),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final cwd in recent)
                    ActionChip(
                      label: Text(shortPath(cwd, _probe?.home)),
                      tooltip: cwd,
                      onPressed: () => _cwd.text = cwd,
                    ),
                ],
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _model,
              decoration: InputDecoration(labelText: t.sessions.model, hintText: t.sessions.modelHint),
              onSubmitted: ready ? (_) => unawaited(_create()) : null,
            ),
            if (error != null) ...[
              const SizedBox(height: 12),
              Text(error, style: TextStyle(color: theme.colorScheme.error)),
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
      final files = _files = await widget.runtime.link.files();
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
      final directories = [
        for (final entry in entries)
          if (entry.stat.isDirectory && entry.name != '.' && entry.name != '..') entry.name,
      ]..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
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
                Expanded(
                  child: Text(path == null ? '' : hostPath(path), maxLines: 2, overflow: TextOverflow.ellipsis),
                ),
                IconButton(
                  tooltip: t.sessions.showHidden,
                  isSelected: _showHidden,
                  icon: const Icon(Icons.visibility_off_outlined),
                  selectedIcon: const Icon(Icons.visibility_outlined),
                  onPressed: () => setState(() => _showHidden = !_showHidden),
                ),
              ],
            ),
            const Divider(height: 1),
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
