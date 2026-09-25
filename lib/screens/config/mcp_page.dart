import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';

import '../../config/config_target.dart';
import '../../config/mcp_config.dart';
import '../../config/txt_command.dart';
import '../../i18n/strings.g.dart';
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
  final _search = TextEditingController();

  LiveSession? get _project => widget.target.projectSession;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
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

  /// Runs `/mcp …` where [scope] lives and shows its output.
  Future<void> _run(String line, McpScope scope, {bool reload = true, bool secret = false}) async {
    setState(() {
      _running = true;
      // A token must not show on screen after the command ran.
      _command = secret ? line.replaceAll(RegExp(r'--token \S+'), '--token ••••') : line;
      _output = null;
    });
    await runReporting(context, () async {
      final session = scope == McpScope.project ? _project ?? (throw StateError('no project session')) : await widget.target.control();
      final output = await runTxtCommand(session, line);
      if (mounted) setState(() => _output = output);
      if (reload) await _load();
    }, secret: secret);
    if (mounted) setState(() => _running = false);
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
    if (spec == null) return;
    final line = spec.transport == 'stdio'
        ? mcpAddStdio(spec.name, spec.scope, spec.target)
        : mcpAddRemote(spec.name, spec.scope, url: spec.target, transport: spec.transport, token: spec.token);
    await _run(line, spec.scope, secret: spec.token != null);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final servers = _servers;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.mcp,
          subtitle: [t.config.mcp.userFile(path: _userFile), if (_projectFile case final file?) t.config.mcp.projectFile(path: file)].join('\n'),
          actions: [
            FilledButton.icon(onPressed: _running ? null : _add, icon: const Icon(Icons.add), label: Text(t.config.mcp.add)),
            const SizedBox(width: 8),
            IconButton(tooltip: t.config.refresh, onPressed: _loading ? null : _load, icon: const Icon(Icons.refresh)),
          ],
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              OutlinedButton(onPressed: _running ? null : () => _run('/mcp reload', McpScope.user, reload: false), child: Text(t.config.mcp.reload)),
              OutlinedButton(
                onPressed: _running ? null : () => _run('/mcp resources', _project == null ? McpScope.user : McpScope.project, reload: false),
                child: Text(t.config.mcp.resources),
              ),
              OutlinedButton(
                onPressed: _running ? null : () => _run('/mcp prompts', _project == null ? McpScope.user : McpScope.project, reload: false),
                child: Text(t.config.mcp.prompts),
              ),
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    isDense: true,
                    border: const OutlineInputBorder(),
                    hintText: t.config.mcp.smithery,
                    suffixIcon: IconButton(
                      icon: const Icon(Icons.search),
                      onPressed: _running || _search.text.trim().isEmpty
                          ? null
                          : () => _run('/mcp smithery-search ${_search.text.trim()}', McpScope.user, reload: false),
                    ),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (text) {
                    if (text.trim().isNotEmpty) unawaited(_run('/mcp smithery-search ${text.trim()}', McpScope.user, reload: false));
                  },
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        const Divider(height: 1),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
            children: [
              if (_error != null) ConfigError(_error!, onRetry: _load),
              if (servers == null && _error == null) const Center(child: CircularProgressIndicator()),
              if (servers != null && servers.isEmpty) Padding(padding: const EdgeInsets.all(8), child: Text(t.config.mcp.none)),
              for (final server in servers ?? const <McpServer>[])
                Card.outlined(
                  margin: const EdgeInsets.symmetric(vertical: 4),
                  child: ListTile(
                    leading: Icon(server.transport == 'stdio' ? Icons.terminal : Icons.cloud_outlined),
                    title: Text(server.name),
                    subtitle: Text(
                      '${server.transport} · ${server.scope == McpScope.user ? t.config.mcp.userScope : t.config.mcp.projectScope}'
                      '${server.target == null ? '' : '\n${server.target}'}',
                      style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                    ),
                    isThreeLine: server.target != null,
                    trailing: Wrap(
                      spacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Switch(
                          value: server.enabled,
                          onChanged: _running || (server.scope == McpScope.project && _project == null)
                              ? null
                              : (enabled) => _run('/mcp ${enabled ? 'enable' : 'disable'} ${server.name}', server.scope),
                        ),
                        if (server.enabled)
                          TextButton(
                            onPressed: _running ? null : () => _run('/mcp test ${server.name}', server.scope, reload: false),
                            child: Text(t.config.mcp.test),
                          )
                        else
                          // omp loads only enabled servers; `/mcp test` of a disabled one answers "not found".
                          Tooltip(
                            message: t.config.mcp.testDisabled,
                            child: TextButton(onPressed: null, child: Text(t.config.mcp.test)),
                          ),
                        IconButton(
                          tooltip: t.common.delete,
                          onPressed: _running || (server.scope == McpScope.project && _project == null) ? null : () => _remove(server),
                          icon: const Icon(Icons.delete_outline),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_command != null) ...[
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(child: Text(_command!, style: theme.textTheme.labelLarge?.copyWith(fontFamily: 'monospace'))),
                    if (_running) const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  ],
                ),
                const SizedBox(height: 8),
                if (_output != null) CommandOutputView(_output!.isEmpty ? t.config.noOutput : _output!),
              ],
              const SizedBox(height: 16),
              Text(t.config.mcp.tuiOnly, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
        ),
      ],
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
    final name = _name.text.trim();
    final problem = mcpNameProblem(name);
    if (problem != null) {
      setState(() => _nameError = problem);
      return;
    }
    if (_target.text.trim().isEmpty) return;
    // A token in a project session's prompt would land in its run log; only the control process (no log)
    // takes one.
    final token = _transport != 'stdio' && _scope == McpScope.user && _token.text.trim().isNotEmpty ? _token.text.trim() : null;
    Navigator.pop(context, (name: name, scope: _scope, transport: _transport, target: _target.text.trim(), token: token));
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
            TextField(
              key: const ValueKey('mcp-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: t.config.mcp.name, errorText: _nameError, border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            SegmentedButton<McpScope>(
              segments: [
                ButtonSegment(value: McpScope.user, label: Text(t.config.mcp.userScope)),
                ButtonSegment(value: McpScope.project, label: Text(t.config.mcp.projectScope), enabled: widget.projectAvailable),
              ],
              selected: {_scope},
              onSelectionChanged: (selection) => setState(() => _scope = selection.single),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const [
                ButtonSegment(value: 'stdio', label: Text('stdio')),
                ButtonSegment(value: 'http', label: Text('http')),
                ButtonSegment(value: 'sse', label: Text('sse')),
              ],
              selected: {_transport},
              onSelectionChanged: (selection) => setState(() => _transport = selection.single),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('mcp-target'),
              controller: _target,
              decoration: InputDecoration(
                labelText: _transport == 'stdio' ? t.config.mcp.command : t.config.mcp.url,
                hintText: _transport == 'stdio' ? 'npx -y @modelcontextprotocol/server-everything' : 'https://example.com/mcp',
                border: const OutlineInputBorder(),
              ),
            ),
            if (_transport != 'stdio') ...[
              const SizedBox(height: 12),
              TextField(
                controller: _token,
                enabled: _scope == McpScope.user,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: t.config.mcp.token,
                  helperText: _scope == McpScope.user ? t.config.mcp.tokenHint : t.config.mcp.tokenUserOnly,
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
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
