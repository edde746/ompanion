import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:omp_core/companion.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';

import '../../config/config_target.dart';
import '../../config/config_yaml.dart';
import '../../config/settings_schema.dart';
import '../../config/settings_view.dart';
import '../../i18n/strings.g.dart';
import 'config_widgets.dart';
import 'setting_editors.dart';

/// omp's settings, from the companion's schema, with the edited file's own values and the effective layer.
///
/// Global scope writes through `settings.set` / `settings.unset` in the machine's control process (omp
/// persists `config.yml` itself). Project scope edits `<cwd>/.omp/config.yml` of the active session over
/// SFTP; omp has no writer for it and watches the file.
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  SettingsScope _scope = SettingsScope.global;
  SettingsSchema? _schema;
  SettingsSnapshot? _effective;
  LiveSession? _source;
  ConfigLayer? _global;
  Object? _globalError;
  String? _globalPath;
  ConfigLayer? _project;
  Object? _projectError;
  String? _projectPath;
  Object? _error;
  bool _loading = true;
  String? _tab;
  final _search = TextEditingController();
  final Set<String> _busy = {};
  StreamSubscription<CompanionEvent>? _events;
  StreamSubscription<LinkState>? _links;
  Timer? _fileReload;
  Future<void> _projectEdits = Future.value();

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    unawaited(_links?.cancel());
    _fileReload?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    // Also called after awaited work, when the page may be gone.
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final control = await widget.target.control();
      final schema =
          _schema ?? SettingsSchema.fromJson(asJsonObject(await control.companion.call('settings.schema'), 'settings.schema'));
      final project = widget.target.projectSession;
      if (_scope == SettingsScope.project && project == null) _scope = SettingsScope.global;
      final source = _scope == SettingsScope.project ? project! : control;
      if (!mounted) return;
      _watch(source);
      final effective = SettingsSnapshot.fromJson(asJsonObject(await source.companion.call('settings.get'), 'settings.get'));
      await _loadFiles();
      if (!mounted) return;
      setState(() {
        _schema = schema;
        _effective = effective;
        _source = source;
        _tab ??= schema.tabs.firstOrNull ?? advancedTab;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Follows `settings.changed` of [source]; a reconnect brings a new companion client, so a link that
  /// comes back live reloads the page.
  void _watch(LiveSession source) {
    unawaited(_events?.cancel());
    unawaited(_links?.cancel());
    _events = source.companion.events.listen(
      (event) {
        if (!mounted || event.event != 'settings.changed' || _effective == null) return;
        final changed = SettingsSnapshot.fromJson(asJsonObject(event.data, 'settings.changed'));
        setState(() => _effective = _effective!.merge(changed));
        // The file watcher, another device or the TUI may have written the files.
        _fileReload?.cancel();
        _fileReload = Timer(const Duration(milliseconds: 300), () => unawaited(_reloadFiles()));
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = error);
      },
    );
    var wasLive = source.linkState is LinkLive;
    _links = source.linkStates.listen((state) {
      final live = state is LinkLive;
      if (live && !wasLive) unawaited(_load());
      wasLive = live;
    });
  }

  Future<void> _loadFiles() async {
    final target = widget.target;
    try {
      final path = _globalPath ??= await target.globalConfigPath();
      final text = await target.readText(path);
      _global = text == null ? const ConfigLayer({}) : ConfigLayer.parse(text);
      _globalError = null;
    } on Object catch (error) {
      _global = null;
      _globalError = error;
    }
    final session = widget.target.projectSession;
    if (_scope != SettingsScope.project || session == null) {
      _project = null;
      _projectPath = null;
      return;
    }
    try {
      final path = _projectPath = target.projectConfigPath(session.cwd);
      final text = await target.readText(path);
      _project = text == null ? const ConfigLayer({}) : ConfigLayer.parse(text);
      _projectError = null;
    } on Object catch (error) {
      _project = null;
      _projectError = error;
    }
  }

  Future<void> _reloadFiles() async {
    await _loadFiles();
    if (mounted) setState(() {});
  }

  void _setScope(SettingsScope scope) {
    if (scope == _scope) return;
    setState(() {
      _scope = scope;
      _effective = null;
    });
    unawaited(_load());
  }

  Future<void> _write(SettingSchema setting, Object? value) =>
      _mutate(setting, () async {
        switch (_scope) {
          case SettingsScope.global:
            final control = await widget.target.control();
            if (setting.secret) {
              final file = await widget.target.uploadSecret(jsonEncode(value));
              try {
                _applyResult(
                  control,
                  await control.companion.call('settings.set', {'path': setting.path, 'scope': 'global', 'valueFile': file}),
                );
              } finally {
                await widget.target.discardSecret(file);
              }
            } else {
              _applyResult(
                control,
                await control.companion.call('settings.set', {'path': setting.path, 'scope': 'global', 'value': value}),
              );
            }
          case SettingsScope.project:
            await _editProject((text) => setConfigValue(text ?? '', setting.segments, value));
        }
      });

  Future<void> _reset(SettingSchema setting) =>
      _mutate(setting, () async {
        switch (_scope) {
          case SettingsScope.global:
            final control = await widget.target.control();
            _applyResult(control, await control.companion.call('settings.unset', {'path': setting.path, 'scope': 'global'}));
          case SettingsScope.project:
            await _editProject((text) => text == null ? null : removeConfigValue(text, setting.segments));
        }
      });

  /// Applies [edit] to the project file's text (null when the file is absent); a null result writes nothing.
  /// Each edit reads, changes and writes the whole file, so edits run one at a time: a second one reads the
  /// first one's result, not the text both started from.
  Future<void> _editProject(String? Function(String? text) edit) async {
    final path = _projectPath ?? (throw StateError('no project file'));
    final previous = _projectEdits;
    final done = Completer<void>();
    _projectEdits = done.future;
    try {
      await previous;
      final updated = edit(await widget.target.readText(path));
      if (updated != null) await widget.target.writeText(path, updated);
    } finally {
      done.complete();
    }
  }

  Future<void> _mutate(SettingSchema setting, Future<void> Function() change) async {
    setState(() => _busy.add(setting.path));
    await runReporting(context, () async {
      await change();
      await _loadFiles();
    }, secret: setting.secret);
    if (mounted) setState(() => _busy.remove(setting.path));
  }

  /// A `settings.set` / `settings.unset` reply is the new effective value in the control process.
  void _applyResult(LiveSession control, Object? result) {
    if (!identical(control, _source) || _effective == null) return;
    final value = SettingValue.fromJson(asJsonObject(result, 'settings reply'));
    _effective = _effective!.merge(SettingsSnapshot(values: {value.path: value}, conditions: const {}));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final schema = _schema;
    if (schema == null) {
      if (_error != null) return Center(child: ConfigError(_error!, onRetry: _load));
      return const Center(child: CircularProgressIndicator());
    }
    final project = widget.target.projectSession;
    final query = _search.text;
    final tab = _tab ?? advancedTab;
    final effective = _effective;
    final sections = settingsSections(
      schema,
      tab: tab,
      query: query,
      conditions: effective?.conditions ?? schema.conditions,
    );
    final rows = <Widget>[];
    for (final section in sections) {
      rows.add(_SectionHeader(section: section, showTab: query.trim().isNotEmpty));
      for (final setting in section.settings) {
        rows.add(_row(context, setting));
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.settings,
          subtitle: switch (_scope) {
            SettingsScope.global => t.config.settings.editing(path: _globalPath ?? '…'),
            SettingsScope.project => t.config.settings.editing(path: _projectPath ?? '…'),
          },
          actions: [
            if (_loading) const Padding(padding: EdgeInsets.all(12), child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))),
            IconButton(tooltip: t.config.refresh, onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SegmentedButton<SettingsScope>(
                segments: [
                  ButtonSegment(value: SettingsScope.global, label: Text(t.config.scope.global), icon: const Icon(Icons.public)),
                  ButtonSegment(
                    value: SettingsScope.project,
                    enabled: project != null,
                    label: Text(project == null ? t.config.scope.projectNone : t.config.scope.project(name: _basename(project.cwd))),
                    icon: const Icon(Icons.folder_outlined),
                  ),
                ],
                selected: {_scope},
                onSelectionChanged: (selection) => _setScope(selection.single),
              ),
              SizedBox(
                width: 320,
                child: TextField(
                  key: const ValueKey('settings-search'),
                  controller: _search,
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: const Icon(Icons.search),
                    hintText: t.config.settings.search,
                    border: const OutlineInputBorder(),
                    suffixIcon: query.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () => setState(_search.clear),
                          ),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
              ),
            ],
          ),
        ),
        if (_globalError != null) _Banner(t.config.settings.fileError(path: _globalPath ?? 'config.yml', error: '$_globalError')),
        if (_projectError != null) _Banner(t.config.settings.fileError(path: _projectPath ?? '.omp/config.yml', error: '$_projectError')),
        if (_error != null) _Banner('$_error'),
        if (query.trim().isEmpty)
          SizedBox(
            height: 52,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
              children: [
                for (final id in [...schema.tabs, advancedTab])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(_tabLabel(context, id)),
                      selected: id == tab,
                      onSelected: (_) => setState(() => _tab = id),
                    ),
                  ),
              ],
            ),
          ),
        if (query.trim().isEmpty && tab == 'appearance') _Banner(t.config.settings.themeNote, info: true),
        if (query.trim().isEmpty && tab == advancedTab) _Banner(t.config.settings.advancedNote, info: true),
        const Divider(height: 1),
        Expanded(
          child: rows.isEmpty
              ? Center(child: Text(t.config.settings.noMatches))
              : ListView.builder(
                  padding: const EdgeInsets.only(bottom: 32),
                  itemCount: rows.length,
                  itemBuilder: (context, index) => rows[index],
                ),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, SettingSchema setting) {
    final display = displayFor(setting, _effective?.values[setting.path], _scope, global: _global, project: _project);
    final editor = editorFor(setting, display.value);
    final projectSecret = _scope == SettingsScope.project && setting.secret;
    final enabled = !_busy.contains(setting.path) && _effective != null && !projectSecret;
    return _SettingTile(
      key: ValueKey('${_scope.name}:${setting.path}'),
      setting: setting,
      display: display,
      editor: editor,
      enabled: enabled,
      busy: _busy.contains(setting.path),
      note: projectSecret ? context.t.config.settings.secretGlobalOnly : null,
      onChanged: (value) => unawaited(_write(setting, value)),
      onReset: display.setHere && enabled ? () => unawaited(_reset(setting)) : null,
    );
  }
}

String _basename(String path) {
  final parts = path.split(RegExp(r'[\\/]')).where((part) => part.isNotEmpty);
  return parts.isEmpty ? path : parts.last;
}

String _tabLabel(BuildContext context, String id) {
  if (id == advancedTab) return context.t.config.settings.advancedTab;
  return id.isEmpty ? id : '${id[0].toUpperCase()}${id.substring(1)}';
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.section, required this.showTab});

  final SettingsSection section;
  final bool showTab;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tab = _tabLabel(context, section.tab);
    final group = section.group;
    final title = [if (showTab) tab, ?group].join(' · ');
    if (title.isEmpty) return const SizedBox(height: 8);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 4),
      child: Text(title, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner(this.text, {this.info = false});

  final String text;
  final bool info;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: info ? scheme.secondaryContainer : scheme.errorContainer,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Text(
            text,
            style: TextStyle(color: info ? scheme.onSecondaryContainer : scheme.onErrorContainer),
          ),
        ),
      ),
    );
  }
}

class _SettingTile extends StatelessWidget {
  const _SettingTile({
    super.key,
    required this.setting,
    required this.display,
    required this.editor,
    required this.enabled,
    required this.busy,
    required this.onChanged,
    this.onReset,
    this.note,
  });

  final SettingSchema setting;
  final SettingDisplay display;
  final SettingEditor editor;
  final bool enabled;
  final bool busy;
  final SettingChanged onChanged;
  final VoidCallback? onReset;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final effective = display.effective;
    final overriddenBy = display.overriddenBy;
    final trailing = trailingEditor(context, editor, display.value, enabled: enabled, onChanged: onChanged);
    final block = blockEditor(context, setting, editor, display, enabled: enabled, onChanged: onChanged);
    final ui = setting.ui;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 10, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(setting.label, style: theme.textTheme.titleSmall),
                    if (effective != null) ProvenanceBadge(effective.provenance, envName: setting.env?.name),
                    if (overriddenBy != null && effective is KnownValue)
                      Tooltip(
                        message: t.config.settings.overridden(value: describeValue(effective.value)),
                        child: Icon(Icons.info_outline, size: 16, color: theme.colorScheme.tertiary),
                      ),
                    if (busy) const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
              ),
              ?trailing,
              if (onReset != null)
                IconButton(tooltip: t.config.settings.reset, onPressed: onReset, icon: const Icon(Icons.restart_alt, size: 20))
              else
                const SizedBox(width: 40),
            ],
          ),
          if (ui != null && ui.description.isNotEmpty) Text(ui.description, style: muted),
          if (ui?.warning case final warning?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(warning, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
            ),
          if (overriddenBy != null && effective is KnownValue)
            Text(
              t.config.settings.overriddenLine(value: describeValue(effective.value)),
              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary),
            ),
          if (note != null) Text(note!, style: muted),
          Text(setting.path, style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.outline)),
          if (block != null) Padding(padding: const EdgeInsets.only(top: 8, right: 40), child: block),
        ],
      ),
    );
  }
}
