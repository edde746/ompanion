import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';

import '../../app/theme.dart';
import '../../config/config_target.dart';
import '../../config/mcp_config.dart';
import '../../config/txt_command.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/activity_mark.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/labeled_field.dart';
import '../chat/transcript/code_style.dart';
import 'config_widgets.dart';

/// MCP servers from `<agentDir>/mcp.json` and the active project's `.omp/mcp.json`, read over SFTP. Changes
/// go through omp's own `/mcp` subcommands: user-scope ones in the control process, project-scope ones in
/// the active session, whose working directory is the project.
class McpPage extends StatefulWidget {
  const McpPage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<McpPage> createState() => _McpPageState();
}

class _McpPageState extends State<McpPage> {
  List<McpServer>? _servers;
  Object? _error;
  bool _loading = true;
  String? _command;
  String? _output;
  bool _running = false;
  String _smitheryQuery = '';
  String? _smitheryOutput;
  bool _smitherySearching = false;

  LiveSession? get _project => widget.target.projectSession;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  String get _userFile => widget.target.join(widget.target.probe.agentDir, const ['mcp.json']);

  String? get _projectFile {
    final project = _project;
    return project == null ? null : widget.target.join(project.cwd, const ['.omp', 'mcp.json']);
  }

  Future<void> _load() async {
    // Also called after awaited work, when the page may be gone.
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final user = await widget.target.readText(_userFile);
      final projectFile = _projectFile;
      final project = projectFile == null ? null : await widget.target.readText(projectFile);
      final servers = parseMcpServers(user: user, project: project);
      if (mounted) setState(() => _servers = servers);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<LiveSession> _session(McpScope scope) async =>
      scope == McpScope.project ? _project ?? (throw StateError('no project session')) : await widget.target.control();

  /// Runs `/mcp …` where [scope] lives, shows its output under the list and returns it; null when it failed.
  /// [append] adds the command and its output to the ones shown.
  Future<String?> _run(
    String line,
    McpScope scope, {
    bool reload = true,
    bool secret = false,
    bool append = false,
  }) async {
    // A token must not show on screen after the command ran.
    final shown = secret ? line.replaceAll(RegExp(r'--token \S+'), '--token ••••') : line;
    final previous = append ? _output : null;
    setState(() {
      _running = true;
      _command = append && _command != null ? '${_command!}\n$shown' : shown;
      _output = previous;
    });
    String? output;
    await runReporting(context, () async {
      output = await runTxtCommand(await _session(scope), line);
      if (mounted) setState(() => _output = [?previous, output!].join('\n'));
      if (reload) await _load();
    }, secret: secret);
    if (mounted) setState(() => _running = false);
    return output;
  }

  Future<void> _remove(McpServer server) async {
    final t = context.t;
    final confirmed = await confirmAction(
      context,
      title: t.config.mcp.removeTitle(name: server.name),
      body: t.config.mcp.removeBody(scope: server.scope.name),
      action: t.common.delete,
    );
    if (confirmed) await _run('/mcp remove ${server.name} --scope ${server.scope.name}', server.scope);
  }

  Future<void> _add() async {
    final spec = await showDialog<_AddSpec>(
      context: context,
      builder: (_) => _AddServerDialog(projectAvailable: _project != null),
    );
    if (spec == null || !mounted) return;
    final line = spec.transport == 'stdio'
        ? mcpAddStdio(spec.name, spec.scope, spec.target)
        : mcpAddRemote(spec.name, spec.scope, url: spec.target, transport: spec.transport, token: spec.token);
    final output = await _run(line, spec.scope, secret: spec.token != null);
    // omp's `/mcp add` only writes mcp.json and reports "Added MCP server …" without connecting; `/mcp test`
    // connects and says whether the command or URL is an MCP server.
    if (output != null && output.contains('Added MCP server') && mounted) {
      await _run('/mcp test ${spec.name}', spec.scope, reload: false, append: true);
    }
  }

  /// `/mcp smithery-search` as the query changes; a reply to an older query is dropped.
  Future<void> _searchSmithery(String text) async {
    final query = text.trim();
    setState(() {
      _smitheryQuery = query;
      _smitheryOutput = null;
      _smitherySearching = query.isNotEmpty;
    });
    if (query.isEmpty) return;
    String? output;
    try {
      output = await runTxtCommand(await widget.target.control(), '/mcp smithery-search $query');
    } on Object catch (error) {
      output = '$error';
    }
    if (!mounted || query != _smitheryQuery) return;
    setState(() {
      _smitheryOutput = output;
      _smitherySearching = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final servers = _servers;
    final lookupScope = _project == null ? McpScope.user : McpScope.project;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.mcp,
          subtitle: [
            t.config.mcp.userFile(path: _userFile),
            if (_projectFile case final file?) t.config.mcp.projectFile(path: file),
          ].join('\n'),
          actions: [
            FilledButton.icon(
              onPressed: _running ? null : _add,
              icon: const Icon(Icons.add, size: 18),
              label: Text(t.config.mcp.add),
            ),
            RefreshAction(loading: _loading, onPressed: _load),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: AppSizes.gap,
            runSpacing: AppSizes.gap,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilledButton.tonal(
                onPressed: _running ? null : () => _run('/mcp reload', McpScope.user, reload: false),
                child: Text(t.config.mcp.reload),
              ),
              FilledButton.tonal(
                onPressed: _running ? null : () => _run('/mcp resources', lookupScope, reload: false),
                child: Text(t.config.mcp.resources),
              ),
              FilledButton.tonal(
                onPressed: _running ? null : () => _run('/mcp prompts', lookupScope, reload: false),
                child: Text(t.config.mcp.prompts),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            children: [
              if (_error != null) ConfigError(_error!, onRetry: _load),
              if (servers == null && _error == null) const Center(child: ActivityMark(size: 20)),
              if (servers != null && servers.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(t.config.mcp.none)),
              for (final server in servers ?? const <McpServer>[])
                _ServerRow(
                  server: server,
                  running: _running,
                  editable: server.scope == McpScope.user || _project != null,
                  onEnabled: (enabled) => _run('/mcp ${enabled ? 'enable' : 'disable'} ${server.name}', server.scope),
                  onTest: () => _run('/mcp test ${server.name}', server.scope, reload: false),
                  onRemove: () => _remove(server),
                ),
              if (_command case final command?) CommandRun(command: command, running: _running, output: _output),
              ConfigSectionTitle(t.config.mcp.smitheryTitle),
              AppSearchField(
                key: const ValueKey('mcp-smithery'),
                hint: t.config.mcp.smithery,
                debounce: const Duration(milliseconds: 500),
                onChanged: (text) => unawaited(_searchSmithery(text)),
              ),
              if (_smitherySearching)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Align(alignment: AlignmentDirectional.centerStart, child: ActivityMark()),
                ),
              if (_smitheryOutput case final output?)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: CommandOutputView(output.isEmpty ? t.config.noOutput : output),
                ),
              const SizedBox(height: 16),
              Text(
                t.config.mcp.tuiOnly,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A server: transport icon, name, scope and target, then its switch, Test and Delete.
class _ServerRow extends StatelessWidget {
  const _ServerRow({
    required this.server,
    required this.running,
    required this.editable,
    required this.onEnabled,
    required this.onTest,
    required this.onRemove,
  });

  final McpServer server;
  final bool running;

  /// A project server needs the project session to change.
  final bool editable;
  final ValueChanged<bool> onEnabled;
  final VoidCallback onTest;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final test = TextButton(onPressed: running || !server.enabled ? null : onTest, child: Text(t.config.mcp.test));
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ConfigBlock(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
        child: Row(
          children: [
            Icon(
              server.transport == 'stdio' ? Icons.terminal : Icons.cloud_outlined,
              size: 18,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(server.name, style: theme.textTheme.bodyMedium),
                  Text(
                    [
                      server.transport,
                      server.scope == McpScope.user ? t.config.mcp.userScope : t.config.mcp.projectScope,
                    ].join(' · '),
                    style: muted,
                  ),
                  if (server.target case final target?)
                    Text(
                      target,
                      style: codeTextStyle(theme).copyWith(fontSize: muted?.fontSize, color: muted?.color),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                ],
              ),
            ),
            Switch(value: server.enabled, onChanged: running || !editable ? null : onEnabled),
            // omp loads only enabled servers; `/mcp test` of a disabled one answers "not found".
            if (server.enabled) test else Tooltip(message: t.config.mcp.testDisabled, child: test),
            IconButton(
              tooltip: t.common.delete,
              onPressed: running || !editable ? null : onRemove,
              icon: const Icon(Icons.delete_outline, size: 20),
            ),
          ],
        ),
      ),
    );
  }
}

typedef _AddSpec = ({String name, McpScope scope, String transport, String target, String? token});

class _AddServerDialog extends StatefulWidget {
  const _AddServerDialog({required this.projectAvailable});

  final bool projectAvailable;

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  final _name = TextEditingController();
  final _target = TextEditingController();
  final _token = TextEditingController();
  McpScope _scope = McpScope.user;
  String _transport = 'stdio';
  String? _nameError;

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    _token.dispose();
    super.dispose();
  }

  void _save() {
    final t = context.t;
    final name = _name.text.trim();
    final problem = mcpNameProblem(name);
    if (problem != null) {
      setState(
        () => _nameError = switch (problem) {
          McpNameProblem.empty => t.common.required,
          McpNameProblem.tooLong => t.config.mcp.nameTooLong,
          McpNameProblem.invalidCharacters => t.config.mcp.nameInvalid,
        },
      );
      return;
    }
    if (_target.text.trim().isEmpty) return;
    // A token in a project session's prompt would land in its run log; only the control process (no log)
    // takes one.
    final token = _transport != 'stdio' && _scope == McpScope.user && _token.text.trim().isNotEmpty
        ? _token.text.trim()
        : null;
    Navigator.pop(context, (
      name: name,
      scope: _scope,
      transport: _transport,
      target: _target.text.trim(),
      token: token,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(t.config.mcp.addTitle),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LabeledField(
              label: t.config.mcp.name,
              child: TextField(
                key: const ValueKey('mcp-name'),
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(errorText: _nameError),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: AppSizes.gap,
              runSpacing: AppSizes.gap,
              children: [
                AppSegmented<McpScope>(
                  value: _scope,
                  segments: [
                    (McpScope.user, t.config.mcp.userScope, null),
                    (McpScope.project, t.config.mcp.projectScope, null),
                  ],
                  disabled: {if (!widget.projectAvailable) McpScope.project},
                  onChanged: (scope) => setState(() => _scope = scope),
                ),
                AppSegmented<String>(
                  value: _transport,
                  segments: const [('stdio', 'stdio', null), ('http', 'http', null), ('sse', 'sse', null)],
                  onChanged: (transport) => setState(() => _transport = transport),
                ),
              ],
            ),
            const SizedBox(height: 12),
            LabeledField(
              label: _transport == 'stdio' ? t.config.mcp.command : t.config.mcp.url,
              child: TextField(
                key: const ValueKey('mcp-target'),
                controller: _target,
                decoration: InputDecoration(
                  hintText: _transport == 'stdio'
                      ? 'npx -y @modelcontextprotocol/server-everything'
                      : 'https://example.com/mcp',
                ),
              ),
            ),
            if (_transport != 'stdio') ...[
              const SizedBox(height: 12),
              LabeledField(
                label: t.config.mcp.token,
                child: TextField(
                  controller: _token,
                  enabled: _scope == McpScope.user,
                  obscureText: true,
                  decoration: InputDecoration(
                    helperText: _scope == McpScope.user ? t.config.mcp.tokenHint : t.config.mcp.tokenUserOnly,
                    helperMaxLines: 2,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(key: const ValueKey('mcp-add'), onPressed: _save, child: Text(t.config.mcp.add)),
      ],
    );
  }
}
