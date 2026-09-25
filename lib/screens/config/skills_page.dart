import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../config/cli_results.dart';
import '../../config/config_target.dart';
import '../../config/omp_cli.dart';
import '../../i18n/strings.g.dart';
import 'config_widgets.dart';

/// Registry skills (skills.omp.sh): search and info through `omp skill … --json`, the installed ones from
/// `skills.json` / `skills.lock.json` (user: the agent directory; project: `<cwd>/.omp`), install, update
/// and uninstall through the CLI. Project-scope commands run in the active session's directory.
class SkillsPage extends StatefulWidget {
  const SkillsPage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<SkillsPage> createState() => _SkillsPageState();
}

class _SkillsPageState extends State<SkillsPage> {
  List<InstalledSkill>? _installed;
  SkillSearch? _results;
  Object? _error;
  Object? _searchError;
  bool _searching = false;
  bool _running = false;
  String? _command;
  String? _output;
  final _query = TextEditingController();

  String? get _cwd => widget.target.projectSession?.cwd;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInstalled());
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _loadInstalled() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      final target = widget.target;
      final agentDir = target.probe.agentDir;
      final installed = parseInstalledSkills(
        manifest: await target.readText(target.join(agentDir, const ['skills.json'])),
        lock: await target.readText(target.join(agentDir, const ['skills.lock.json'])),
        scope: 'user',
      );
      final cwd = _cwd;
      if (cwd != null) {
        installed.addAll(
          parseInstalledSkills(
            manifest: await target.readText(target.join(cwd, const ['.omp', 'skills.json'])),
            lock: await target.readText(target.join(cwd, const ['.omp', 'skills.lock.json'])),
            scope: 'project',
          ),
        );
      }
      if (mounted) setState(() => _installed = installed);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _search() async {
    final query = _query.text.trim();
    if (query.isEmpty) return;
    setState(() {
      _searching = true;
      _searchError = null;
    });
    try {
      final result = await widget.target.omp(['skill', 'search', query, '--json']);
      final search = SkillSearch.fromJson(asJsonObject(cliJson(result.stdout), 'skill search'));
      if (mounted) setState(() => _results = search);
    } on Object catch (error) {
      if (mounted) setState(() => _searchError = error);
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _info(String id) async {
    SkillPackage? package;
    if (!await runReporting(context, () async {
          final result = await widget.target.omp(['skill', 'info', id, '--json']);
          package = SkillPackage.fromJson(asJsonObject(cliJson(result.stdout), 'skill info'));
        }) ||
        !mounted) {
      return;
    }
    await showDialog<void>(context: context, builder: (_) => _InfoDialog(package: package!));
  }

  /// `omp skill <args>`; `--global` for user scope, the project directory otherwise.
  Future<void> _run(List<String> args, {required bool user}) async {
    final full = ['skill', ...args, if (user) '--global'];
    setState(() {
      _running = true;
      _command = 'omp ${full.join(' ')}';
      _output = null;
    });
    try {
      final result = await widget.target.omp(full, cwd: user ? null : _cwd);
      _output = [result.stdout.trim(), result.stderr.trim()].where((text) => text.isNotEmpty).join('\n');
    } on OmpCliException catch (error) {
      _output = error.message;
      // omp refuses a skill that ships scripts without a terminal to ask on; ask here instead.
      if (error.message.contains('--yes') && args.first == 'install' && mounted) {
        final t = context.t;
        final confirmed = await confirmAction(
          context,
          title: t.config.skills.scriptsTitle,
          body: t.config.skills.scriptsBody,
          action: t.config.skills.installAnyway,
        );
        if (confirmed) {
          setState(() => _running = false);
          await _run([...args, '--yes'], user: user);
          return;
        }
      }
    } on Object catch (error) {
      _output = '$error';
    }
    if (mounted) setState(() => _running = false);
    await _loadInstalled();
  }

  Future<void> _install(String id) async {
    final t = context.t;
    var user = true;
    if (_cwd != null) {
      final choice = await showDialog<bool>(
        context: context,
        builder: (context) => SimpleDialog(
          title: Text(t.config.skills.installWhere(id: id)),
          children: [
            SimpleDialogOption(onPressed: () => Navigator.pop(context, true), child: Text(t.config.skills.forUser)),
            SimpleDialogOption(onPressed: () => Navigator.pop(context, false), child: Text(t.config.skills.forProject(path: _cwd!))),
          ],
        ),
      );
      if (choice == null) return;
      user = choice;
    }
    await _run(['install', id], user: user);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final results = _results;
    final installed = _installed;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.skills,
          subtitle: t.config.skills.registry,
          actions: [IconButton(tooltip: t.config.refresh, onPressed: _loadInstalled, icon: const Icon(Icons.refresh))],
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            children: [
              Text(t.config.skills.installed, style: theme.textTheme.titleMedium),
              if (_error != null) ConfigError(_error!, onRetry: _loadInstalled),
              if (installed == null && _error == null) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
              if (installed != null && installed.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.config.skills.none)),
              for (final skill in installed ?? const <InstalledSkill>[])
                Card.outlined(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    title: Text(skill.id),
                    subtitle: Text(
                      [
                        skill.version ?? t.config.skills.notInstalled,
                        if (skill.range != null) t.config.skills.range(range: skill.range!),
                        skill.scope == 'user' ? t.config.mcp.userScope : t.config.mcp.projectScope,
                      ].join(' · '),
                    ),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        TextButton(onPressed: () => _info(skill.id), child: Text(t.config.skills.info)),
                        TextButton(
                          onPressed: _running ? null : () => _run(['update', skill.id], user: skill.scope == 'user'),
                          child: Text(t.config.plugins.update),
                        ),
                        TextButton(
                          onPressed: _running || (skill.scope == 'project' && _cwd == null)
                              ? null
                              : () => _run(['uninstall', skill.id], user: skill.scope == 'user'),
                          child: Text(t.config.plugins.uninstall),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              Text(t.config.skills.search, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _query,
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        prefixIcon: const Icon(Icons.search),
                        hintText: t.config.skills.searchHint,
                      ),
                      onSubmitted: (_) => _search(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _searching ? null : _search, child: Text(t.config.skills.searchAction)),
                ],
              ),
              if (_searching) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
              if (_searchError != null) ConfigError(_searchError!, onRetry: _search),
              if (results != null) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(t.config.skills.results(shown: '${results.hits.length}', total: '${results.total}'), style: theme.textTheme.bodySmall),
                ),
                for (final hit in results.hits)
                  Card.outlined(
                    margin: const EdgeInsets.symmetric(vertical: 4),
                    child: ListTile(
                      title: Text('${hit.id}@${hit.version}'),
                      subtitle: Text(
                        [
                          ?hit.description,
                          [
                            t.config.skills.downloads(number: '${hit.weeklyDownloads}'),
                            if (hit.publisher != null) t.config.skills.by(name: hit.publisher!),
                            if (hit.keywords.isNotEmpty) hit.keywords.join(', '),
                          ].join(' · '),
                          if (hit.deprecated != null) t.config.skills.deprecated(reason: hit.deprecated!),
                        ].join('\n'),
                      ),
                      isThreeLine: hit.description != null,
                      trailing: Wrap(
                        spacing: 4,
                        children: [
                          TextButton(onPressed: () => _info(hit.id), child: Text(t.config.skills.info)),
                          FilledButton.tonal(onPressed: _running ? null : () => _install(hit.id), child: Text(t.config.plugins.installAction)),
                        ],
                      ),
                    ),
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

class _InfoDialog extends StatelessWidget {
  const _InfoDialog({required this.package});

  final SkillPackage package;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final lines = [
      ?package.description,
      if (package.license != null) t.config.skills.license(license: package.license!),
      if (package.latest != null) t.config.skills.latest(version: package.latest!),
      if (package.versions.isNotEmpty) t.config.skills.versions(versions: package.versions.join(', ')),
      if (package.owners.isNotEmpty) t.config.skills.owners(owners: package.owners.join(', ')),
      if (package.weeklyDownloads != null)
        t.config.skills.downloadsTotal(weekly: '${package.weeklyDownloads}', total: '${package.totalDownloads ?? 0}'),
      if (package.keywords.isNotEmpty) package.keywords.join(', '),
      ?package.repository,
      ?package.homepage,
      if (package.latestHasScripts) t.config.skills.shipsScripts,
    ];
    return AlertDialog(
      title: Text(package.id),
      content: SizedBox(width: 480, child: SelectableText(lines.join('\n\n'))),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close))],
    );
  }
}
