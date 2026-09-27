import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/companion.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';

import '../../config/accounts.dart';
import '../../config/config_target.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/activity_mark.dart';
import '../chat/transcript/code_style.dart';
import 'config_widgets.dart';
import 'model_picker.dart';

/// omp's model roles: the effective model per role with its layer, and the global and project
/// assignments. Global writes go through the control process; project writes through the active session,
/// whose working directory is the project (`roles.set` writes `<cwd>/.omp/config.yml`).
class RolesPage extends StatefulWidget {
  const RolesPage({super.key, required this.target});

  final ConfigTarget target;

  @override
  State<RolesPage> createState() => _RolesPageState();
}

class _RolesPageState extends State<RolesPage> {
  RolesState? _roles;
  Object? _error;
  bool _loading = true;
  final Set<String> _busy = {};
  StreamSubscription<CompanionEvent>? _events;

  LiveSession? get _project => widget.target.projectSession;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    unawaited(_events?.cancel());
    super.dispose();
  }

  /// The session whose view of the roles the page shows: the project's when there is one, since it also
  /// holds the project layer.
  Future<LiveSession> _source() async => _project ?? await widget.target.control();

  Future<void> _load() async {
    // Also called after awaited work, when the page may be gone.
    if (!mounted) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final source = await _source();
      if (!mounted) return;
      unawaited(_events?.cancel());
      _events = source.companion.events.listen((event) {
        if (!mounted || event.event != 'roles.changed') return;
        setState(() => _roles = RolesState.fromJson(asJsonObject(event.data, 'roles.changed')));
      });
      final roles = RolesState.fromJson(asJsonObject(await source.companion.call('roles.get'), 'roles.get'));
      if (mounted) setState(() => _roles = roles);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<List<RpcModel>> _models({bool refresh = false}) async {
    final control = await widget.target.control();
    return widget.target.sessions.models(widget.target.machine, control.rpc, refresh: refresh);
  }

  Future<void> _assign(ModelRole role, {required bool project}) async {
    final t = context.t;
    var models = const <RpcModel>[];
    if (!await runReporting(context, () async => models = await _models()) || !mounted) return;
    final selector = await pickModel(
      context,
      models: models,
      title: t.config.roles.pickTitle(role: role.name),
      current: project ? role.project : role.global,
    );
    if (selector == null) return;
    await _set(role, selector, project: project);
  }

  Future<void> _set(ModelRole role, String? model, {required bool project}) async {
    setState(() => _busy.add(role.role));
    await runReporting(context, () async {
      final session = project ? _project ?? (throw StateError('no project session')) : await widget.target.control();
      final result = await session.companion.call('roles.set', {
        'role': role.role,
        'model': model,
        'scope': project ? 'project' : 'global',
      });
      final roles = RolesState.fromJson(asJsonObject(result, 'roles.set'));
      // The reply of the control process lacks the project layer; the page's own source reports it.
      final source = await _source();
      if (identical(source, session)) {
        if (mounted) setState(() => _roles = roles);
      } else {
        final fresh = RolesState.fromJson(asJsonObject(await source.companion.call('roles.get'), 'roles.get'));
        if (mounted) setState(() => _roles = fresh);
      }
    });
    if (mounted) setState(() => _busy.remove(role.role));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final roles = _roles;
    final project = _project;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConfigHeader(
          title: t.config.sections.roles,
          subtitle: roles == null
              ? null
              : [
                  t.config.roles.storage(storage: roles.storage),
                  if (project != null) t.config.roles.projectIs(path: project.cwd) else t.config.roles.noProject,
                ].join('\n'),
          actions: [
            TextButton.icon(
              onPressed: () =>
                  runReporting(context, () => _models(refresh: true), done: t.config.roles.modelsRefreshed),
              icon: const Icon(Icons.sync),
              label: Text(t.config.roles.refreshModels),
            ),
            RefreshAction(loading: _loading, onPressed: _load),
          ],
        ),
        Expanded(
          child: switch ((roles, _error)) {
            (null, final error?) => Center(child: ConfigError(error, onRetry: _load)),
            (null, _) => const Center(child: ActivityMark(size: 20)),
            (final roles?, _) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
              children: [
                for (final kind in [false, true]) ...[
                  ConfigSectionTitle(kind ? t.config.roles.kindRoles : t.config.roles.chatRoles),
                  for (final role in roles.roles.where((role) => role.kindSection == kind))
                    _RoleCard(
                      role: role,
                      busy: _busy.contains(role.role),
                      projectAvailable: project != null,
                      onAssign: (project) => unawaited(_assign(role, project: project)),
                      onClear: (project) => unawaited(_set(role, null, project: project)),
                    ),
                ],
              ],
            ),
          },
        ),
      ],
    );
  }
}

class _RoleCard extends StatelessWidget {
  const _RoleCard({
    required this.role,
    required this.busy,
    required this.projectAvailable,
    required this.onAssign,
    required this.onClear,
  });

  final ModelRole role;
  final bool busy;
  final bool projectAvailable;
  final ValueChanged<bool> onAssign;
  final ValueChanged<bool> onClear;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final mono = codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodyMedium?.fontSize);
    Widget layer(String label, String? value, {required bool project, required bool available}) => Row(
      children: [
        SizedBox(width: 72, child: Text(label, style: theme.textTheme.labelMedium)),
        Expanded(
          child: Text(
            value ?? t.config.roles.auto,
            style: value == null
                ? theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)
                : mono,
          ),
        ),
        TextButton(
          key: ValueKey('role-${role.role}-${project ? 'project' : 'global'}'),
          onPressed: available && !busy ? () => onAssign(project) : null,
          child: Text(t.config.roles.assign),
        ),
        // Full tone like Set beside it: the default grey of an enabled icon is too close to a disabled one.
        IconButton(
          key: ValueKey('role-${role.role}-${project ? 'project' : 'global'}-clear'),
          tooltip: t.config.roles.clear,
          color: theme.colorScheme.onSurface,
          onPressed: available && !busy && value != null ? () => onClear(project) : null,
          icon: const Icon(Icons.clear, size: 18),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ConfigBlock(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(role.name, style: theme.textTheme.titleSmall),
                const SizedBox(width: 8),
                Text(
                  role.role,
                  style: codeTextStyle(
                    theme,
                  ).copyWith(fontSize: theme.textTheme.labelSmall?.fontSize, color: theme.colorScheme.onSurfaceVariant),
                ),
                const Spacer(),
                if (busy) const ActivityMark(size: 16),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                SizedBox(width: 72, child: Text(t.config.roles.effective, style: theme.textTheme.labelMedium)),
                Flexible(
                  child: Text(
                    role.model ?? t.config.roles.auto,
                    style: role.model == null ? theme.textTheme.bodyMedium : mono,
                  ),
                ),
                const SizedBox(width: 8),
                ProvenanceBadge(role.provenance),
              ],
            ),
            layer(t.config.scope.global, role.global, project: false, available: true),
            layer(t.config.roles.projectLayer, role.project, project: true, available: projectAvailable),
          ],
        ),
      ),
    );
  }
}
