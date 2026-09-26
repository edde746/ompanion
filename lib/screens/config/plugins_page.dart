import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../config/cli_results.dart';
import '../../config/config_target.dart';
import '../../config/omp_cli.dart';
import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/app_segmented.dart';
import '../chat/transcript/code_style.dart';
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
        asJsonObject(
          cliJson((await widget.target.omp(const ['plugin', 'list', '--json'], cwd: _cwd)).stdout),
          'plugin list',
        ),
      );
      final marketplaces = parseMarketplaceList(
        (await widget.target.omp(const ['plugin', 'marketplace', 'list'], cwd: _cwd)).stdout,
      );
      final available = <String, List<AvailablePlugin>>{};
      for (final marketplace in marketplaces) {
        available[marketplace.name] = parseDiscover(
          (await widget.target.omp(['plugin', 'discover', marketplace.name], cwd: _cwd)).stdout,
        );
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

  /// Runs `omp plugin <args>`, shows what it printed, reloads, and returns whether omp succeeded.
  Future<bool> _run(List<String> args) async {
    setState(() {
      _running = true;
      _command = 'omp plugin ${args.join(' ')}';
      _output = null;
    });
    var ok = false;
    try {
      final result = await widget.target.omp(['plugin', ...args], cwd: _cwd);
      _output = [result.stdout.trim(), result.stderr.trim()].where((text) => text.isNotEmpty).join('\n');
      ok = true;
    } on OmpCliException catch (error) {
      _output = error.message;
    } on Object catch (error) {
      _output = '$error';
    }
    if (mounted) setState(() => _running = false);
    await _load();
    return ok;
  }

  Future<void> _addMarketplace() async {
    final source = _source.text.trim();
    if (source.isEmpty) return;
    if (await _run(['marketplace', 'add', source]) && mounted) setState(_source.clear);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final mono = codeTextStyle(theme)
        .copyWith(fontSize: theme.textTheme.labelSmall?.fontSize, color: theme.colorScheme.onSurfaceVariant);
    final plugins = _plugins;
    final installed = {...?plugins?.marketplace.map((plugin) => plugin.id)};
    final installField = TextField(
      controller: _install,
      decoration: InputDecoration(hintText: t.config.plugins.installPlaceholder),
      onChanged: (_) => setState(() {}),
    );
    final scope = AppSegmented<String>(
      value: _scope,
      segments: [('user', t.config.mcp.userScope, null), ('project', t.config.mcp.projectScope, null)],
      disabled: {if (_cwd == null) 'project'},
      onChanged: (scope) => setState(() => _scope = scope),
    );
    final installButton = FilledButton(
      onPressed: _running || _install.text.trim().isEmpty
          ? null
          : () => _run([
              'install',
              _install.text.trim(),
              if (_scope == 'project') ...['--scope', 'project'],
            ]),
      child: Text(t.config.plugins.installAction),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.plugins,
          subtitle: _cwd == null ? null : t.config.plugins.inProject(path: _cwd!),
          actions: [RefreshAction(loading: _loading, onPressed: _load)],
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              if (_error != null) ConfigError(_error!, onRetry: _load),
              if (plugins == null && _error == null) const Center(child: CircularProgressIndicator()),
              if (plugins != null) ...[
                ConfigSectionTitle(t.config.plugins.installed),
                if (plugins.isEmpty) Text(t.config.plugins.none, style: muted),
                for (final plugin in plugins.npm)
                  _Row(
                    title: '${plugin.name}@${plugin.version}',
                    lines: [
                      if (plugin.description != null) Text(plugin.description!, style: muted),
                      Text([t.config.plugins.npm, ?plugin.path].join(' · '), style: mono),
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
                    actions: [
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
                for (final plugin in plugins.marketplace)
                  _Row(
                    title: '${plugin.id}${plugin.version == null ? '' : ' (${plugin.version})'}',
                    lines: [
                      Text(
                        [
                          t.config.plugins.marketplaceScope(scope: plugin.scope),
                          if (plugin.shadowedBy != null) t.config.plugins.shadowed,
                        ].join(' · '),
                        style: muted,
                      ),
                    ],
                    actions: [
                      Switch(
                        value: plugin.enabled,
                        onChanged: _running
                            ? null
                            : (on) => _run([on ? 'enable' : 'disable', plugin.id, '--scope', plugin.scope, '--json']),
                      ),
                      TextButton(
                        onPressed: _running ? null : () => _run(['upgrade', plugin.id, '--scope', plugin.scope]),
                        child: Text(t.config.plugins.upgrade),
                      ),
                      TextButton(
                        onPressed: _running ? null : () => _run(['uninstall', plugin.id, '--scope', plugin.scope]),
                        child: Text(t.config.plugins.uninstall),
                      ),
                    ],
                  ),
                ConfigSectionTitle(t.config.plugins.install),
                Text(t.config.plugins.installHint, style: muted),
                const SizedBox(height: AppSizes.gap),
                LayoutBuilder(
                  builder: (context, constraints) => constraints.maxWidth >= 520
                      ? Row(
                          children: [
                            Expanded(child: installField),
                            const SizedBox(width: AppSizes.gap),
                            scope,
                            const SizedBox(width: AppSizes.gap),
                            installButton,
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            installField,
                            const SizedBox(height: AppSizes.gap),
                            Row(children: [scope, const Spacer(), installButton]),
                          ],
                        ),
                ),
                ConfigSectionTitle(
                  t.config.plugins.marketplaces,
                  trailing: TextButton(
                    onPressed: _running || _marketplaces.isEmpty ? null : () => _run(['marketplace', 'update']),
                    child: Text(t.config.plugins.updateAll),
                  ),
                ),
                if (_marketplaces.isEmpty) Text(t.config.plugins.noMarketplaces, style: muted),
                for (final marketplace in _marketplaces)
                  _Row(
                    title: marketplace.name,
                    lines: [
                      Text(marketplace.source, style: mono),
                      for (final plugin in _available[marketplace.name] ?? const <AvailablePlugin>[])
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '${plugin.name}${plugin.version == null ? '' : '@${plugin.version}'}',
                                      style: theme.textTheme.bodyMedium,
                                    ),
                                    if (plugin.description != null) Text(plugin.description!, style: muted),
                                  ],
                                ),
                              ),
                              if (installed.contains('${plugin.name}@${marketplace.name}'))
                                ConfigTag(t.config.plugins.isInstalled)
                              else
                                TextButton(
                                  onPressed: _running
                                      ? null
                                      : () => _run([
                                          'install',
                                          '${plugin.name}@${marketplace.name}',
                                          if (_scope == 'project') ...['--scope', 'project'],
                                        ]),
                                  child: Text(t.config.plugins.installAction),
                                ),
                            ],
                          ),
                        ),
                    ],
                    actions: [
                      TextButton(
                        onPressed: _running ? null : () => _run(['marketplace', 'update', marketplace.name]),
                        child: Text(t.config.plugins.update),
                      ),
                      TextButton(
                        onPressed: _running ? null : () => _run(['marketplace', 'remove', marketplace.name]),
                        child: Text(t.common.delete),
                      ),
                    ],
                  ),
                const SizedBox(height: AppSizes.gap),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        key: const ValueKey('marketplace-source'),
                        controller: _source,
                        decoration: InputDecoration(hintText: t.config.plugins.sourcePlaceholder),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: (_) => _running ? null : _addMarketplace(),
                      ),
                    ),
                    const SizedBox(width: AppSizes.gap),
                    FilledButton.tonal(
                      onPressed: _running || _source.text.trim().isEmpty ? null : _addMarketplace,
                      child: Text(t.config.plugins.addMarketplace),
                    ),
                  ],
                ),
              ],
              if (_command case final command?) CommandRun(command: command, running: _running, output: _output),
            ],
          ),
        ),
      ],
    );
  }
}

/// A flat block: a title with its actions, and lines under it.
class _Row extends StatelessWidget {
  const _Row({required this.title, required this.lines, required this.actions});

  final String title;
  final List<Widget> lines;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: ConfigBlock(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(title, style: Theme.of(context).textTheme.bodyMedium)),
              ...actions,
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
          ),
        ],
      ),
    ),
  );
}
