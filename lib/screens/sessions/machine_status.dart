import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../machines/connect_dialogs.dart';

/// Rebuilds with every status of [runtime].
class MachineStatusBuilder extends StatelessWidget {
  const MachineStatusBuilder({super.key, required this.runtime, required this.builder});

  final MachineRuntime runtime;
  final Widget Function(BuildContext context, MachineStatus status) builder;

  @override
  Widget build(BuildContext context) => StreamBuilder<MachineStatus>(
    stream: runtime.statuses,
    builder: (context, _) => builder(context, runtime.status),
  );
}

/// One line for [status]: offline, connecting, the omp version, what is missing, or why connecting failed.
String machineStatusText(Translations t, MachineStatus status) => switch (status) {
  MachineOffline() => t.sessions.offline,
  MachineConnecting() => t.sessions.connecting,
  MachineOnline(:final probe) => t.sessions.online(version: probe.ompVersion ?? '?'),
  MachineNeedsOmp(:final reason) => t.sessions.needsOmp(reason: reason),
  MachineFailed(:final cause) => describeConnectError(t, cause),
};

/// The dot on a machine's icon: grey offline or connecting, success online, warning without omp, error when failed.
Color machineStatusColor(BuildContext context, MachineStatus status) {
  final colors = AppColors.of(context);
  return switch (status) {
    MachineOffline() || MachineConnecting() => Theme.of(context).colorScheme.onSurfaceVariant,
    MachineOnline() => colors.success,
    MachineNeedsOmp() => colors.warning,
    MachineFailed() => colors.error,
  };
}
