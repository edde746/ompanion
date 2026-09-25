import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';

import '../../config/config_target.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../sessions/sessions_provider.dart';
import 'accounts_page.dart';
import 'config_widgets.dart';
import 'mcp_page.dart';
import 'plugins_page.dart';
import 'roles_page.dart';
import 'settings_page.dart';
import 'skills_page.dart';
import 'stats_page.dart';
import 'usage_page.dart';

/// Opens the omp configuration of [machine] as its own page.
Future<void> openMachineConfig(BuildContext context, Machine machine) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MachineConfigScreen(machine: machine)));

enum ConfigSection { settings, roles, accounts, mcp, plugins, skills, usage, stats }

/// Machine-level omp configuration: settings, model roles, providers and accounts, MCP servers, plugins,
/// skills, usage and stats. Talks to the machine's control process and runs `omp` one-shots.
class MachineConfigScreen extends StatefulWidget {
  const MachineConfigScreen({super.key, required this.machine, this.initialSection = ConfigSection.settings});

  final Machine machine;
  final ConfigSection initialSection;

  @override
  State<MachineConfigScreen> createState() => _MachineConfigScreenState();
}

class _MachineConfigScreenState extends State<MachineConfigScreen> {
  late final ConfigTarget _target = ConfigTarget(machine: widget.machine, sessions: context.read<SessionsProvider>());
  late ConfigSection _section = widget.initialSection;
  bool _connecting = false;
  Object? _connectError;

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final runtime = _target.runtime;
    if (runtime.status is MachineOnline) return;
    setState(() {
      _connecting = true;
      _connectError = null;
    });
    try {
      await runtime.connectAndProbe();
    } on Object catch (error) {
      _connectError = error;
    }
    if (mounted) setState(() => _connecting = false);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    // The active session decides the project scope.
    context.watch<SessionsProvider>();
    final runtime = _target.runtime;
    return Scaffold(
      appBar: AppBar(title: Text(t.config.title(machine: widget.machine.name))),
      body: StreamBuilder<MachineStatus>(
        stream: runtime.statuses,
        initialData: runtime.status,
        builder: (context, snapshot) => switch (snapshot.data ?? runtime.status) {
          MachineOnline() => _sections(context),
          MachineNeedsOmp(:final reason) => Center(child: ConfigError(t.config.needsOmp(reason: reason))),
          MachineFailed(:final cause) => Center(child: ConfigError(cause, onRetry: _connect)),
          MachineConnecting() => _progress(t.config.connecting),
          MachineOffline() when _connectError != null => Center(child: ConfigError(_connectError!, onRetry: _connect)),
          MachineOffline() when _connecting => _progress(t.config.connecting),
          MachineOffline() => Center(
            child: FilledButton.icon(onPressed: _connect, icon: const Icon(Icons.link), label: Text(t.config.connect)),
          ),
        },
      ),
    );
  }

  Widget _progress(String label) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(label)],
    ),
  );

  Widget _sections(BuildContext context) {
    final t = context.t;
    final labels = {
      ConfigSection.settings: (t.config.sections.settings, Icons.tune),
      ConfigSection.roles: (t.config.sections.roles, Icons.psychology_alt_outlined),
      ConfigSection.accounts: (t.config.sections.accounts, Icons.key_outlined),
      ConfigSection.mcp: (t.config.sections.mcp, Icons.hub_outlined),
      ConfigSection.plugins: (t.config.sections.plugins, Icons.extension_outlined),
      ConfigSection.skills: (t.config.sections.skills, Icons.school_outlined),
      ConfigSection.usage: (t.config.sections.usage, Icons.speed),
      ConfigSection.stats: (t.config.sections.stats, Icons.bar_chart),
    };
    final page = KeyedSubtree(
      key: ValueKey(_section),
      child: switch (_section) {
        ConfigSection.settings => SettingsPage(target: _target),
        ConfigSection.roles => RolesPage(target: _target),
        ConfigSection.accounts => AccountsPage(target: _target),
        ConfigSection.mcp => McpPage(target: _target),
        ConfigSection.plugins => PluginsPage(target: _target),
        ConfigSection.skills => SkillsPage(target: _target),
        ConfigSection.usage => UsagePage(target: _target),
        ConfigSection.stats => StatsPage(target: _target),
      },
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 800) {
          return Row(
            children: [
              NavigationRail(
                extended: constraints.maxWidth >= 1100,
                labelType: constraints.maxWidth >= 1100 ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                selectedIndex: _section.index,
                onDestinationSelected: (index) => setState(() => _section = ConfigSection.values[index]),
                destinations: [
                  for (final section in ConfigSection.values)
                    NavigationRailDestination(icon: Icon(labels[section]!.$2), label: Text(labels[section]!.$1)),
                ],
              ),
              Expanded(child: page),
            ],
          );
        }
        return Column(
          children: [
            ColoredBox(
              color: Theme.of(context).colorScheme.surfaceContainerLow,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: ConfigPills<ConfigSection>(
                  value: _section,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  items: [for (final section in ConfigSection.values) (section, labels[section]!.$1, labels[section]!.$2)],
                  onChanged: (section) => setState(() => _section = section),
                ),
              ),
            ),
            Expanded(child: page),
          ],
        );
      },
    );
  }
}
