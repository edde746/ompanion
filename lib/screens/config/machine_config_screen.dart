import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';

import '../../app/window_chrome.dart';
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

/// Opens the omp configuration of [machine] as its own page.
Future<void> openMachineConfig(BuildContext context, Machine machine) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => MachineConfigScreen(machine: machine)));

enum ConfigSection { settings, roles, accounts, mcp, plugins, skills, stats }

/// Machine-level omp configuration: settings, model roles, providers, MCP servers, plugins, skills and stats. Talks
/// to the machine's control process and runs `omp` one-shots.
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
    final title = Text(t.config.title(machine: widget.machine.name));
    Widget plain(Widget body) => Scaffold(
      appBar: windowAppBar(context, title: title),
      body: body,
    );
    return StreamBuilder<MachineStatus>(
      stream: runtime.statuses,
      initialData: runtime.status,
      builder: (context, snapshot) => switch (snapshot.data ?? runtime.status) {
        MachineOnline() => _sections(context, title),
        MachineNeedsOmp(:final reason) => plain(Center(child: ConfigError(t.config.needsOmp(reason: reason)))),
        MachineFailed(:final cause) => plain(Center(child: ConfigError(cause, onRetry: _connect))),
        MachineConnecting() => plain(_progress(t.config.connecting)),
        MachineOffline() when _connectError != null => plain(
          Center(child: ConfigError(_connectError!, onRetry: _connect)),
        ),
        MachineOffline() when _connecting => plain(_progress(t.config.connecting)),
        MachineOffline() => plain(
          Center(
            child: FilledButton.icon(onPressed: _connect, icon: const Icon(Icons.link), label: Text(t.config.connect)),
          ),
        ),
      },
    );
  }

  Widget _progress(String label) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [const CircularProgressIndicator(), const SizedBox(height: 12), Text(label)],
    ),
  );

  Widget _sections(BuildContext context, Widget title) {
    final t = context.t;
    final labels = {
      ConfigSection.settings: (t.config.sections.settings, Icons.tune),
      ConfigSection.roles: (t.config.sections.roles, Icons.psychology_alt_outlined),
      ConfigSection.accounts: (t.config.sections.accounts, Icons.key_outlined),
      ConfigSection.mcp: (t.config.sections.mcp, Icons.hub_outlined),
      ConfigSection.plugins: (t.config.sections.plugins, Icons.extension_outlined),
      ConfigSection.skills: (t.config.sections.skills, Icons.school_outlined),
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
        ConfigSection.stats => StatsPage(target: _target),
      },
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 800) {
          final extended = constraints.maxWidth >= 1100;
          // Like the shell's sidebar with its header, the navigation is one surface from the top edge down with
          // the back button at its top; the title bar covers only the page.
          return Scaffold(
            body: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Material(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: SafeArea(
                    right: false,
                    child: Column(
                      // Puts the back button over the rail's icons: the extended rail centres them in its first
                      // _railWidth, the collapsed one across its width, which its longest label sets.
                      crossAxisAlignment: extended ? CrossAxisAlignment.start : CrossAxisAlignment.center,
                      children: [
                        // On macOS the traffic lights sit over the rail's top; the back button goes below them.
                        if (WindowChrome.trafficLights(context))
                          const WindowDragArea(
                            child: SizedBox(width: _railWidth, height: trafficLightsBottom - 8),
                          ),
                        const SizedBox(
                          width: _railWidth,
                          height: kToolbarHeight,
                          child: Center(child: BackButton()),
                        ),
                        Expanded(
                          child: NavigationRail(
                            minWidth: _railWidth,
                            // Seven labelled destinations do not fit below the back button on a landscape tablet
                            // or in a short window.
                            scrollable: true,
                            extended: extended,
                            labelType: extended ? NavigationRailLabelType.none : NavigationRailLabelType.all,
                            selectedIndex: _section.index,
                            onDestinationSelected: (index) => setState(() => _section = ConfigSection.values[index]),
                            destinations: [
                              for (final section in ConfigSection.values)
                                NavigationRailDestination(
                                  icon: Icon(labels[section]!.$2),
                                  label: Text(labels[section]!.$1),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      AppBar(
                        automaticallyImplyLeading: false,
                        centerTitle: false,
                        title: title,
                        // In a column the bar's height is not bounded from outside: the area takes the toolbar's.
                        flexibleSpace: const WindowDragArea(
                          child: SizedBox(width: double.infinity, height: kToolbarHeight),
                        ),
                      ),
                      // The title bar took the top inset; without this, list pages would pad by it again.
                      Expanded(
                        child: MediaQuery.removePadding(context: context, removeTop: true, child: page),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          );
        }
        return Scaffold(
          appBar: windowAppBar(context, title: title),
          body: Column(
            children: [
              ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: ConfigPills<ConfigSection>(
                    value: _section,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    items: [
                      for (final section in ConfigSection.values) (section, labels[section]!.$1, labels[section]!.$2),
                    ],
                    onChanged: (section) => setState(() => _section = section),
                  ),
                ),
              ),
              Expanded(child: page),
            ],
          ),
        );
      },
    );
  }
}

/// Width of the collapsed navigation rail (Material 3's default); its icons are centred in it.
const double _railWidth = 80;
