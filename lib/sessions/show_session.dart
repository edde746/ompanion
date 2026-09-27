import 'package:omp_core/session.dart';

import '../models/machine.dart';
import '../providers/shell_provider.dart';
import 'sessions_provider.dart';

/// The session a notification points at: the run [runId] on the machine [machineId] while it lives, else the session
/// file [sessionPath] (docs/contracts/push.md, "Receiving").
final class SessionTarget {
  const SessionTarget({required this.machineId, this.runId, this.sessionPath});

  /// Throws [FormatException] when [json] is not a target.
  factory SessionTarget.fromJson(Object? json) {
    if (json is Map) {
      final (machineId, runId, sessionPath) = (json['machineId'], json['runId'], json['sessionPath']);
      if (machineId is String && runId is String? && sessionPath is String?) {
        return SessionTarget(machineId: machineId, runId: runId, sessionPath: sessionPath);
      }
    }
    throw FormatException('not a notification target: $json');
  }

  final String machineId;
  final String? runId;
  final String? sessionPath;

  Map<String, Object?> toJson() => {'machineId': machineId, 'runId': runId, 'sessionPath': sessionPath};

  @override
  bool operator ==(Object other) =>
      other is SessionTarget &&
      other.machineId == machineId &&
      other.runId == runId &&
      other.sessionPath == sessionPath;

  @override
  int get hashCode => Object.hash(machineId, runId, sessionPath);
}

/// Shows a session of [machine] in the center pane. The one this device has open for [runId] or [sessionPath] is
/// selected; otherwise the live run [runId] is attached, or once it ended the file [sessionPath] is resumed, which
/// attaches to the live run holding the file or launches one. A session whose link closed is opened again in place.
Future<void> showSession(
  SessionsProvider sessions,
  ShellProvider shell,
  Machine machine, {
  String? runId,
  String? sessionPath,
}) async {
  final open = sessions.openSessions
      .where(
        (session) =>
            sessions.machineOf(session)?.id == machine.id &&
            ((runId != null && session.runId == runId) || (sessionPath != null && session.sessionPath == sessionPath)),
      )
      .firstOrNull;
  if (open != null && open.linkState is! LinkClosed) {
    sessions.select(open);
  } else if (runId != null) {
    try {
      await sessions.open(machine, AttachRun(runId));
    } on Object catch (error) {
      if ((error is! RunEnded && error is! RunGone) || sessionPath == null) rethrow;
      await sessions.open(machine, ResumeSession(sessionPath));
    }
  } else if (sessionPath != null) {
    await sessions.open(machine, ResumeSession(sessionPath));
  } else {
    throw ArgumentError('a session to show needs a run id or a session file');
  }
  shell.select(const SessionSelection());
}
