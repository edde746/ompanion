import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/companion.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../../app/theme.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/machine.dart';
import '../../../sessions/machine_images.dart';
import '../../../sessions/session_view_builder.dart';
import '../../../sessions/sessions_provider.dart';
import '../../../utils/token_count.dart';
import '../../../widgets/activity_mark.dart';
import '../../chat/transcript/transcript_view.dart';
import '../dock_controller.dart';
import '../dock_empty_state.dart';
import '../machine_access.dart';
import 'agent_roster.dart';
import 'agent_transcript.dart';

/// The Agent Hub: every subagent and advisor of the session, their progress and usage, and one agent's transcript
/// with steer, kill and revive.
class AgentHubTab extends StatefulWidget {
  const AgentHubTab({super.key, required this.session, required this.machine});

  final LiveSession session;
  final Machine machine;

  @override
  State<AgentHubTab> createState() => _AgentHubTabState();
}

class _AgentHubTabState extends State<AgentHubTab> {
  var _tree = false;
  String? _selectedId;
  AgentTranscript? _transcript;
  late final DockController _dock = context.read<DockController>();

  @override
  void initState() {
    super.initState();
    _selectedId = _dock.takeAgentRequest();
    _dock.addListener(_onDockRequest);
  }

  @override
  void didUpdateWidget(AgentHubTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) _select(null);
  }

  void _onDockRequest() {
    final id = _dock.takeAgentRequest();
    if (id != null) _select(id);
  }

  void _select(String? id) {
    if (id == _selectedId) return;
    _transcript?.dispose();
    _transcript = null;
    setState(() => _selectedId = id);
  }

  /// The transcript of [agent], created when first shown.
  AgentTranscript _transcriptFor(RosterAgent agent) {
    final current = _transcript;
    if (current != null && current.agentId == agent.id) return current;
    current?.dispose();
    final runtime = context.read<SessionsProvider>().runtimeFor(widget.machine);
    return _transcript = AgentTranscript(
      session: widget.session,
      agentId: agent.id,
      sessionFile: agent.sessionFile,
      openFiles: () async {
        final (link, _) = await machineAccess(runtime);
        return link.files();
      },
    );
  }

  @override
  void dispose() {
    _dock.removeListener(_onDockRequest);
    _transcript?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SessionViewSelector<(List<AgentRow>, List<Subagent>)>(
      session: widget.session,
      select: (view) => (view.agents, view.subagents),
      builder: (context, lists) {
        final roster = buildRoster(lists.$1, lists.$2);
        final selected = roster.where((agent) => agent.id == _selectedId).firstOrNull;
        if (selected == null && _selectedId != null && roster.isNotEmpty) {
          // The selected agent left the roster (the session changed): back to the list.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !roster.any((agent) => agent.id == _selectedId)) _select(null);
          });
        }
        if (selected != null) {
          final transcript = _transcriptFor(selected)..live = selected.active;
          return _AgentDetail(
            key: ValueKey(selected.id),
            session: widget.session,
            agent: selected,
            transcript: transcript,
            onBack: () => _select(null),
            onOpenAgent: _select,
          );
        }
        return _Roster(
          roster: roster,
          tree: _tree,
          onToggleTree: () => setState(() => _tree = !_tree),
          onSelect: (agent) => _select(agent.id),
        );
      },
    );
  }
}

class _Roster extends StatelessWidget {
  const _Roster({required this.roster, required this.tree, required this.onToggleTree, required this.onSelect});

  final List<RosterAgent> roster;
  final bool tree;
  final VoidCallback onToggleTree;
  final ValueChanged<RosterAgent> onSelect;

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.hub;
    final theme = Theme.of(context);
    if (roster.isEmpty) return DockEmptyState(icon: Symbols.hub, message: t.empty);
    final sections = rosterSections(roster, tree: tree);
    final running = roster.where((agent) => agent.status == RosterStatus.running).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  t.summary(count: roster.length, running: running),
                  style: theme.textTheme.labelLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                ),
              ),
              IconButton(
                tooltip: tree ? t.showList : t.showTree,
                isSelected: tree,
                onPressed: onToggleTree,
                icon: const Icon(Symbols.format_list_bulleted),
                selectedIcon: const Icon(Symbols.account_tree),
              ),
            ],
          ),
        ),
        Expanded(
          child: CustomScrollView(
            slivers: [
              for (final (label, rows) in [(t.active, sections.active), (t.inactive, sections.inactive)])
                if (rows.isNotEmpty) ...[
                  SliverToBoxAdapter(child: _SectionLabel(label)),
                  SliverList.builder(
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final row = rows[index];
                      return _RosterTile(
                        key: ValueKey(row.agent.id),
                        agent: row.agent,
                        depth: row.depth,
                        onTap: () => onSelect(row.agent),
                      );
                    },
                  ),
                ],
            ],
          ),
        ),
      ],
    );
  }
}

/// "Active" or "Inactive" over its part of the roster, in line with the tiles' status icons.
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Text(text, style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
    );
  }
}

class _RosterTile extends StatelessWidget {
  const _RosterTile({super.key, required this.agent, required this.depth, required this.onTap});

  final RosterAgent agent;
  final int depth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final t = context.t.dock.hub;
    final subtitle = agent.activity ?? agent.task;
    final usage = _usageLine(context, agent);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(12.0 + depth * 16, 8, 12, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: StatusIcon(status: agent.status),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          agent.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall,
                        ),
                      ),
                      if (agent.agentType case final type?) ...[const SizedBox(width: 6), _Tag(text: type)],
                      if (agent.kind == AgentKind.advisor) ...[const SizedBox(width: 6), _Tag(text: t.advisor)],
                    ],
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  if (usage.isNotEmpty)
                    Text(usage, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `12.3K tok · 4 tools · $0.02 · 1m 5s`, from whatever the agent reports.
String _usageLine(BuildContext context, RosterAgent agent) {
  final t = context.t.dock.hub;
  return [
    if (agent.tokens case final tokens? when tokens > 0) t.tokens(count: formatTokens(tokens)),
    if (agent.tools case final tools? when tools > 0) t.tools(n: tools),
    if (agent.cost case final cost? when cost > 0) '\$${cost.toStringAsFixed(cost < 0.01 ? 4 : 2)}',
    if (agent.duration case final duration? when duration > Duration.zero) _duration(context, duration),
  ].join(' · ');
}

String _duration(BuildContext context, Duration duration) {
  final t = context.t.dock.hub;
  if (duration.inHours > 0) return t.durationHours(hours: duration.inHours, minutes: duration.inMinutes % 60);
  if (duration.inMinutes > 0) return t.durationMinutes(minutes: duration.inMinutes, seconds: duration.inSeconds % 60);
  return t.durationSeconds(seconds: duration.inSeconds);
}

class _Tag extends StatelessWidget {
  const _Tag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(text, style: theme.textTheme.labelSmall),
    );
  }
}

/// An agent's state as an icon, the activity mark while it runs.
class StatusIcon extends StatelessWidget {
  const StatusIcon({super.key, required this.status});

  final RosterStatus status;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final colors = AppColors.of(context);
    final t = context.t.dock.hub.status;
    final (Widget icon, String label) = switch (status) {
      RosterStatus.running => (ActivityMark(color: colors.running), t.running),
      RosterStatus.pending => (Icon(Symbols.schedule, size: 16, color: muted), t.pending),
      RosterStatus.idle => (Icon(Symbols.pause_circle, size: 16, color: muted), t.idle),
      RosterStatus.parked => (Icon(Symbols.bedtime, size: 16, color: muted), t.parked),
      RosterStatus.completed => (Icon(Symbols.check_circle, size: 16, color: colors.success, fill: 1), t.completed),
      RosterStatus.failed => (Icon(Symbols.error, size: 16, color: colors.error, fill: 1), t.failed),
      RosterStatus.aborted => (Icon(Symbols.cancel, size: 16, color: muted, fill: 1), t.aborted),
    };
    return Tooltip(
      message: label,
      child: SizedBox.square(dimension: 16, child: Center(child: icon)),
    );
  }
}

String _statusLabel(BuildContext context, RosterStatus status) {
  final t = context.t.dock.hub.status;
  return switch (status) {
    RosterStatus.running => t.running,
    RosterStatus.pending => t.pending,
    RosterStatus.idle => t.idle,
    RosterStatus.parked => t.parked,
    RosterStatus.completed => t.completed,
    RosterStatus.failed => t.failed,
    RosterStatus.aborted => t.aborted,
  };
}

class _AgentDetail extends StatefulWidget {
  const _AgentDetail({
    super.key,
    required this.session,
    required this.agent,
    required this.transcript,
    required this.onBack,
    required this.onOpenAgent,
  });

  final LiveSession session;
  final RosterAgent agent;
  final AgentTranscript transcript;
  final VoidCallback onBack;
  final ValueChanged<String> onOpenAgent;

  @override
  State<_AgentDetail> createState() => _AgentDetailState();
}

class _AgentDetailState extends State<_AgentDetail> {
  final _steer = TextEditingController();
  var _busy = false;
  var _taskExpanded = false;

  @override
  void dispose() {
    _steer.dispose();
    super.dispose();
  }

  void _snack(String message) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
  }

  /// Whether the call succeeded; a failure is shown.
  Future<bool> _call(String verb, Map<String, Object?> args, {String? done}) async {
    // Without the companion a `/ompx` call would reach the model as a prompt; the UI offers none then.
    if (widget.session.companionHello == null) return false;
    setState(() => _busy = true);
    try {
      await widget.session.companion.call(verb, args);
      if (done != null && mounted) _snack(done);
      return true;
    } on CompanionException catch (error) {
      if (mounted) _snack(context.t.dock.hub.failed(error: error.message));
    } on RpcException catch (error) {
      if (mounted) _snack(context.t.dock.hub.failed(error: error.message));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    return false;
  }

  Future<void> _sendSteer() async {
    final text = _steer.text.trim();
    if (text.isEmpty) return;
    final t = context.t.dock.hub;
    if (await _call('subagent.steer', {'id': widget.agent.id, 'text': text}, done: t.steered) && mounted) {
      _steer.clear();
    }
  }

  Future<void> _kill() async {
    final t = context.t.dock.hub;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.killTitle(name: widget.agent.name)),
        content: Text(t.killBody),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(context.t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.kill)),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _call('subagent.kill', {'id': widget.agent.id}, done: t.killed);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.hub;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final agent = widget.agent;
    final withCompanion = widget.session.companionHello != null;
    final dock = context.read<DockController>();
    final details = [
      ?agent.agentType,
      ?agent.model,
      if (agent.contextTokens case final used? when agent.contextWindow != null && agent.contextWindow! > 0)
        t.context(percent: (used * 100 / agent.contextWindow!).round()),
    ].join(' · ');
    final usage = _usageLine(context, agent);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Row(
            children: [
              IconButton(tooltip: t.back, onPressed: widget.onBack, icon: const Icon(Symbols.arrow_back)),
              StatusIcon(status: agent.status),
              const SizedBox(width: 8),
              Expanded(
                child: Text(agent.name, style: theme.textTheme.titleSmall, overflow: TextOverflow.ellipsis),
              ),
              Text(_statusLabel(context, agent.status), style: theme.textTheme.labelMedium),
              PopupMenuButton<String>(
                tooltip: t.actions,
                icon: const Icon(Symbols.more_vert),
                enabled: !_busy,
                itemBuilder: (context) => [
                  if (withCompanion && agent.canRevive) PopupMenuItem(value: 'revive', child: Text(t.revive)),
                  if (withCompanion && agent.canKill) PopupMenuItem(value: 'kill', child: Text(t.kill)),
                  PopupMenuItem(value: 'copyId', child: Text(t.copyId)),
                ],
                onSelected: (action) async {
                  switch (action) {
                    case 'revive':
                      await _call('subagent.revive', {'id': agent.id}, done: t.revived);
                    case 'kill':
                      await _kill();
                    case 'copyId':
                      await Clipboard.setData(ClipboardData(text: agent.id));
                      if (context.mounted) _snack(context.t.common.copied);
                  }
                },
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (details.isNotEmpty)
                Text(details, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
              if (usage.isNotEmpty)
                Text(usage, style: theme.textTheme.labelSmall?.copyWith(color: scheme.onSurfaceVariant)),
              if (agent.task case final task?)
                GestureDetector(
                  onTap: () => setState(() => _taskExpanded = !_taskExpanded),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      task,
                      maxLines: _taskExpanded ? null : 3,
                      overflow: _taskExpanded ? null : TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ),
            ],
          ),
        ),
        Expanded(
          child: ListenableBuilder(
            listenable: widget.transcript,
            builder: (context, _) {
              final transcript = widget.transcript;
              if (!transcript.loaded) return const Center(child: ActivityMark(size: 20));
              if (transcript.view.transcript.isEmpty) {
                return DockEmptyState(
                  icon: transcript.error == null ? Symbols.forum : Symbols.error,
                  message: transcript.error == null
                      ? t.noTranscript
                      : t.transcriptFailed(error: transcript.error.toString()),
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (transcript.error case final error?)
                    Material(
                      color: AppColors.of(context).errorSurface,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                        child: Text(
                          t.transcriptFailed(error: error.toString()),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).error),
                        ),
                      ),
                    ),
                  Expanded(
                    child: TranscriptView(
                      view: transcript.view,
                      alignTop: true,
                      foldTurns: false,
                      actions: TranscriptActions(
                        onCopy: (text) async {
                          await Clipboard.setData(ClipboardData(text: text));
                          if (context.mounted) _snack(context.t.common.copied);
                        },
                        onOpenFile: (path, {line}) => dock.openFile(path, line: line),
                        onOpenSubagent: widget.onOpenAgent,
                        images: context.read<MachineImages?>()?.forSession(
                          context.read<SessionsProvider>(),
                          widget.session,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
        if (agent.readOnly)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(t.advisorReadOnly, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          )
        else if (agent.canSteer && !withCompanion)
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(t.noCompanion, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          )
        else if (agent.canSteer)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _steer,
                    enabled: !_busy,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => _sendSteer(),
                    decoration: InputDecoration(
                      hintText: agent.status == RosterStatus.parked ? t.steerParkedHint : t.steerHint,
                    ),
                  ),
                ),
                const SizedBox(width: AppSizes.gap),
                IconButton.filled(
                  tooltip: t.steer,
                  onPressed: _busy ? null : _sendSteer,
                  icon: const Icon(Symbols.arrow_upward, size: 20),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
