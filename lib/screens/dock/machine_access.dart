import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';

/// The machine's link and probe, connecting first when needed. Terminal and Files need no omp, so a machine that
/// lacks it ([MachineNeedsOmp]) works too.
Future<(HostLink, HostProbe)> machineAccess(MachineRuntime runtime) async {
  final probe = switch (runtime.status) {
    MachineOnline(:final probe) || MachineNeedsOmp(:final probe) => probe,
    _ => await runtime.connectAndProbe(),
  };
  try {
    return (runtime.link, probe);
  } on StateError {
    // The link dropped after the status was read.
    final fresh = await runtime.connectAndProbe();
    return (runtime.link, fresh);
  }
}
