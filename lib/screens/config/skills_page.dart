import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../config/cli_results.dart';
import '../../config/config_target.dart';
import '../../config/omp_cli.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/activity_mark.dart';
import '../../widgets/app_search_field.dart';
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
  String _query = '';

  String? get _cwd => widget.target.projectSession?.cwd;

  @override
  void initState() {
    super.initState();
    unawaited(_loadInstalled());
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

  /// `omp skill search` as the query changes; a reply to an older query is dropped.
  Future<void> _search(String text) async {
    final query = text.trim();
    setState(() {
      _query = query;
      _searchError = null;
      _results = null;
      _searching = query.isNotEmpty;
    });
    if (query.isEmpty) return;
    SkillSearch? search;
    Object? failure;
    try {
      final result = await widget.target.omp(['skill', 'search', query, '--json']);
      search = SkillSearch.fromJson(asJsonObject(cliJson(result.stdout), 'skill search'));
    } on Object catch (error) {
      failure = error;
    }
    if (!mounted || query != _query) return;
    setState(() {
      _results = search;
      _searchError = failure;
      _searching = false;
    });
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
    await showDialog<void>(
      context: context,
      builder: (_) => _InfoDialog(package: package!),
    );
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
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t.config.skills.forProject(path: _cwd!)),
            ),
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
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
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
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              ConfigSectionTitle(t.config.skills.installed),
              if (_error != null) ConfigError(_error!, onRetry: _loadInstalled),
              if (installed == null && _error == null)
                const Align(alignment: AlignmentDirectional.centerStart, child: ActivityMark()),
              if (installed != null && installed.isEmpty) Text(t.config.skills.none, style: muted),
              for (final skill in installed ?? const <InstalledSkill>[])
                _SkillRow(
                  title: skill.id,
                  subtitle: [
                    skill.version ?? t.config.skills.notInstalled,
                    if (skill.range != null) t.config.skills.range(range: skill.range!),
                    skill.scope == 'user' ? t.config.mcp.userScope : t.config.mcp.projectScope,
                  ].join(' · '),
                  actions: [
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
              ConfigSectionTitle(t.config.skills.search),
              AppSearchField(
                key: const ValueKey('skills-search'),
                hint: t.config.skills.searchHint,
                debounce: const Duration(milliseconds: 500),
                onChanged: (text) => unawaited(_search(text)),
              ),
              if (_searching)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Align(alignment: AlignmentDirectional.centerStart, child: ActivityMark()),
                ),
              if (_searchError != null) ConfigError(_searchError!, onRetry: () => _search(_query)),
              if (results != null && results.hits.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(t.config.skills.noHits(query: _query), style: muted),
                ),
              if (results != null && results.hits.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    t.config.skills.results(shown: '${results.hits.length}', total: '${results.total}'),
                    style: muted,
                  ),
                ),
                for (final hit in results.hits)
                  _SkillRow(
                    title: '${hit.id}@${hit.version}',
                    subtitle: [
                      ?hit.description,
                      [
                        t.config.skills.downloads(number: '${hit.weeklyDownloads}'),
                        if (hit.publisher != null) t.config.skills.by(name: hit.publisher!),
                        if (hit.keywords.isNotEmpty) hit.keywords.join(', '),
                      ].join(' · '),
                      if (hit.deprecated != null) t.config.skills.deprecated(reason: hit.deprecated!),
                    ].join('\n'),
                    actions: [
                      TextButton(onPressed: () => _info(hit.id), child: Text(t.config.skills.info)),
                      FilledButton.tonal(
                        onPressed: _running ? null : () => _install(hit.id),
                        child: Text(t.config.plugins.installAction),
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

/// A skill: its id, a secondary line and its actions on a flat block.
class _SkillRow extends StatelessWidget {
  const _SkillRow({required this.title, required this.subtitle, required this.actions});

  final String title;
  final String subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ConfigBlock(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.bodyMedium),
                  Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            ...actions,
          ],
        ),
      ),
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
