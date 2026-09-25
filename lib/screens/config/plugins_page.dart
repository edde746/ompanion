import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../config/cli_results.dart';
import '../../config/config_target.dart';
import '../../config/omp_cli.dart';
import '../../i18n/strings.g.dart';
import 'config_widgets.dart';

/// Installed plugins (`omp plugin list --json`), marketplaces and what they offer, and the lifecycle
/// commands. Commands run in the active project's directory when there is one, so project-scope
/// marketplace installs show up too.
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  PluginList? _plugins;
  List<MarketplaceSource> _marketplaces = const [];
  final Map<String, List<AvailablePlugin>> _available = {};
  Object? _error;
  bool _loading = true;
  bool _running = false;
  String? _command;
  String? _output;
  final _install = TextEditingController();
  final _source = TextEditingController();
  String _scope = 'user';

  String? get _cwd => widget.target.projectSession?.cwd;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _install.dispose();
    _source.dispose();
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
      final list = PluginList.fromJson(
        asJsonObject(cliJson((await widget.target.omp(const ['plugin', 'list', '--json'], cwd: _cwd)).stdout), 'plugin list'),
      );
      final marketplaces = parseMarketplaceList((await widget.target.omp(const ['plugin', 'marketplace', 'list'], cwd: _cwd)).stdout);
      final available = <String, List<AvailablePlugin>>{};
      for (final marketplace in marketplaces) {
        available[marketplace.name] = parseDiscover((await widget.target.omp(['plugin', 'discover', marketplace.name], cwd: _cwd)).stdout);
      }
      if (!mounted) return;
      setState(() {
        _plugins = list;
        _marketplaces = marketplaces;
        _available
          ..clear()
          ..addAll(available);
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Runs `omp plugin <args>`, shows what it printed, and reloads.
  Future<void> _run(List<String> args) async {
    setState(() {
      _running = true;
      _command = 'omp plugin ${args.join(' ')}';
      _output = null;
    });
    try {
      final result = await widget.target.omp(['plugin', ...args], cwd: _cwd);
      _output = [result.stdout.trim(), result.stderr.trim()].where((text) => text.isNotEmpty).join('\n');
    } on OmpCliException catch (error) {
      _output = error.message;
    } on Object catch (error) {
      _output = '$error';
    }
    if (mounted) setState(() => _running = false);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final plugins = _plugins;
    final installed = {...?plugins?.marketplace.map((plugin) => plugin.id)};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.plugins,
          subtitle: _cwd == null ? null : t.config.plugins.inProject(path: _cwd!),
          actions: [IconButton(tooltip: t.config.refresh, onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh))],
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            children: [
              if (_error != null) ConfigError(_error!, onRetry: _load),
              if (plugins == null && _error == null) const Center(child: CircularProgressIndicator()),
              if (plugins != null) ...[
                Text(t.config.plugins.installed, style: theme.textTheme.titleMedium),
                if (plugins.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.config.plugins.none)),
                for (final plugin in plugins.npm)
                  Card.outlined(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text('${plugin.name}@${plugin.version}', style: theme.textTheme.titleSmall),
                              ),
                              Switch(
                                value: plugin.enabled,
                                onChanged: _running ? null : (on) => _run([on ? 'enable' : 'disable', plugin.name, '--json']),
                              ),
                              TextButton(
                                onPressed: _running ? null : () => _run(['uninstall', plugin.name, '--json']),
                                child: Text(t.config.plugins.uninstall),
                              ),
                            ],
                          ),
                          if (plugin.description != null) Text(plugin.description!, style: theme.textTheme.bodySmall),
                          Text(
                            [t.config.plugins.npm, ?plugin.path].join(' · '),
                            style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.outline),
                          ),
                          if (plugin.features.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  for (final MapEntry(key: feature, value: description) in plugin.features.entries)
                                    FilterChip(
                                      label: Text(feature),
                                      tooltip: description,
                                      selected: plugin.enabledFeatures?.contains(feature) ?? false,
                                      onSelected: _running
                                          ? null
                                          : (on) => _run(['features', plugin.name, on ? '--enable' : '--disable', feature]),
                                    ),
                                ],
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                for (final plugin in plugins.marketplace)
                  Card.outlined(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      title: Text('${plugin.id}${plugin.version == null ? '' : ' (${plugin.version})'}'),
                      subtitle: Text(
                        [t.config.plugins.marketplaceScope(scope: plugin.scope), if (plugin.shadowedBy != null) t.config.plugins.shadowed].join(' · '),
                      ),
                      trailing: Wrap(
                        spacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Switch(
                            value: plugin.enabled,
                            onChanged: _running ? null : (on) => _run([on ? 'enable' : 'disable', plugin.id, '--scope', plugin.scope, '--json']),
                          ),
                          TextButton(onPressed: _running ? null : () => _run(['upgrade', plugin.id, '--scope', plugin.scope]), child: Text(t.config.plugins.upgrade)),
                          TextButton(
                            onPressed: _running ? null : () => _run(['uninstall', plugin.id, '--scope', plugin.scope]),
                            child: Text(t.config.plugins.uninstall),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 24),
                Text(t.config.plugins.install, style: theme.textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(t.config.plugins.installHint, style: theme.textTheme.bodySmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 360,
                      child: TextField(
                        controller: _install,
                        decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: t.config.plugins.installPlaceholder),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    SegmentedButton<String>(
                      segments: [
                        ButtonSegment(value: 'user', label: Text(t.config.mcp.userScope)),
                        ButtonSegment(value: 'project', label: Text(t.config.mcp.projectScope), enabled: _cwd != null),
                      ],
                      selected: {_scope},
                      onSelectionChanged: (selection) => setState(() => _scope = selection.single),
                    ),
                    FilledButton(
                      onPressed: _running || _install.text.trim().isEmpty
                          ? null
                          : () => _run(['install', _install.text.trim(), if (_scope == 'project') ...['--scope', 'project']]),
                      child: Text(t.config.plugins.installAction),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: Text(t.config.plugins.marketplaces, style: theme.textTheme.titleMedium)),
                    TextButton(onPressed: _running || _marketplaces.isEmpty ? null : () => _run(['marketplace', 'update']), child: Text(t.config.plugins.updateAll)),
                  ],
                ),
                if (_marketplaces.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.config.plugins.noMarketplaces)),
                for (final marketplace in _marketplaces)
                  Card.outlined(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(marketplace.name, style: theme.textTheme.titleSmall)),
                              TextButton(onPressed: _running ? null : () => _run(['marketplace', 'update', marketplace.name]), child: Text(t.config.plugins.update)),
                              TextButton(onPressed: _running ? null : () => _run(['marketplace', 'remove', marketplace.name]), child: Text(t.common.delete)),
                            ],
                          ),
                          Text(marketplace.source, style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'monospace', color: theme.colorScheme.outline)),
                          for (final plugin in _available[marketplace.name] ?? const <AvailablePlugin>[])
                            ListTile(
                              dense: true,
                              contentPadding: EdgeInsets.zero,
                              title: Text('${plugin.name}${plugin.version == null ? '' : '@${plugin.version}'}'),
                              subtitle: plugin.description == null ? null : Text(plugin.description!),
                              trailing: installed.contains('${plugin.name}@${marketplace.name}')
                                  ? Chip(label: Text(t.config.plugins.isInstalled))
                                  : TextButton(
                                      onPressed: _running
                                          ? null
                                          : () => _run([
                                              'install',
                                              '${plugin.name}@${marketplace.name}',
                                              if (_scope == 'project') ...['--scope', 'project'],
                                            ]),
                                      child: Text(t.config.plugins.installAction),
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    SizedBox(
                      width: 360,
                      child: TextField(
                        controller: _source,
                        decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: t.config.plugins.sourcePlaceholder),
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                    OutlinedButton(
                      onPressed: _running || _source.text.trim().isEmpty ? null : () => _run(['marketplace', 'add', _source.text.trim()]),
                      child: Text(t.config.plugins.addMarketplace),
                    ),
                  ],
                ),
              ],
              if (_command != null) ...[
                const SizedBox(height: 24),
                Row(
                  children: [
                    Expanded(child: Text(_command!, style: theme.textTheme.labelLarge?.copyWith(fontFamily: 'monospace'))),
                    if (_running) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
                const SizedBox(height: 8),
                if (_output != null) CommandOutputView(_output!.isEmpty ? t.config.noOutput : _output!),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
