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

/// Shows a session of [machine] in the center pane, through [openAndShow]. The one this device has open for [runId] or
/// [sessionPath] is selected; otherwise the live run [runId] is attached, or once it ended the file [sessionPath] is
/// resumed, which attaches to the live run holding the file or launches one. A session whose link closed is opened
/// again in place.
Future<void> showSession(
  SessionsProvider sessions,
  ShellProvider shell,
  Machine machine, {
  String? runId,
  String? sessionPath,
}) => openAndShow(sessions, shell, () => _openSession(sessions, machine, runId: runId, sessionPath: sessionPath));

/// Opens a session with [open] and shows it in the center pane, unless the user navigated elsewhere while it opened:
/// their last choice wins ([ShellProvider.isLatest]). The session stays open either way.
Future<void> openAndShow(SessionsProvider sessions, ShellProvider shell, Future<LiveSession> Function() open) async {
  final turn = shell.takeTurn();
  final session = await open();
  if (!shell.isLatest(turn)) return;
  sessions.select(session);
  shell.select(const SessionSelection());
}

Future<LiveSession> _openSession(
  SessionsProvider sessions,
  Machine machine, {
  required String? runId,
  required String? sessionPath,
}) async {
  final open = sessions.openSessions
      .where(
        (session) =>
            sessions.machineOf(session)?.id == machine.id &&
            ((runId != null && session.runId == runId) || (sessionPath != null && session.sessionPath == sessionPath)),
      )
      .firstOrNull;
  if (open != null && open.linkState is! LinkClosed) return open;
  if (runId != null) {
    try {
      return await sessions.open(machine, AttachRun(runId));
    } on Object catch (error) {
      if ((error is! RunEnded && error is! RunGone) || sessionPath == null) rethrow;
    }
  }
  if (sessionPath == null) throw ArgumentError('a session to show needs a run id or a session file');
  return sessions.open(machine, ResumeSession(sessionPath));
}
