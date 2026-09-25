import 'package:flutter/material.dart';
import 'package:omp_core/session.dart';

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

/// The dot in front of a machine: grey offline, primary online, tertiary without omp, error when failed.
Color machineStatusColor(ColorScheme scheme, MachineStatus status) => switch (status) {
  MachineOffline() || MachineConnecting() => scheme.outline,
  MachineOnline() => scheme.primary,
  MachineNeedsOmp() => scheme.tertiary,
  MachineFailed() => scheme.error,
};
