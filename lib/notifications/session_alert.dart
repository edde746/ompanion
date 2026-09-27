import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:omp_core/host.dart' show NotificationKind;
import 'package:omp_core/store.dart';

import '../i18n/strings.g.dart';
import '../sessions/session_name.dart';

/// A notification about a session: what it is about and the text under its title.
typedef SessionAlert = ({NotificationKind kind, String body});

/// The notification [after] calls for, the view that followed [before]: the desktop's copy of what the companion sends
/// a phone (docs/contracts/push.md, "What the companion sends"). Null when the change calls for none, and while the
/// session is [onScreen]. A session another omp process writes has no run of the app's to report on. [runStartGoal] is
/// the goal as the run that ends began: only a goal completed during that run names its notification, since the view
/// keeps a completed goal after the companion let it go.
///
/// - input: a dialog opened that was not open before; the composer text an extension sets and a login link are no
///   questions.
/// - failed: a run ended in an error, or with its automatic retries given up (`auto_retry_end` comes before the run's
///   terminal `agent_end`); retries that give up after the run ended.
/// - done: a run ended with no goal or loop about to start the next turn, or a running loop ended. A run the user
///   stopped calls for nothing.
SessionAlert? sessionAlert(
  Translations t,
  SessionView before,
  SessionView after, {
  required bool onScreen,
  required Goal? runStartGoal,
}) {
  if (onScreen || after.external != null) return null;
  for (final request in after.requests) {
    if (!_asks(request) || before.requests.any((open) => open.id == request.id)) continue;
    return (kind: NotificationKind.input, body: _clip(_question(t, request), _bodyLength));
  }
  if (before.run.running && !after.run.running) {
    // `agent_start` resets the outcome, so a failure `before` holds is this run's given-up retries.
    final retries = switch (before.run.outcome) {
      RunFailed(:final message) => _nonEmpty(message) ?? t.notifications.runFailed,
      _ => null,
    };
    return switch (after.run.outcome) {
      RunAborted() => null,
      RunFailed(:final message) => _failed(t, _nonEmpty(message) ?? retries),
      RunIdle() when retries != null => _failed(t, retries),
      RunIdle() when _continues(after) => null,
      RunIdle() => (
        kind: NotificationKind.done,
        body: _doneBody(t, after, goalCompleted: _completed(runStartGoal, after)),
      ),
    };
  }
  // A retry that failed to start after the run ended gives up on its own.
  if (!after.run.running && before.run.retrying != null && after.run.retrying == null) {
    if (after.run.outcome case RunFailed(:final message)) return _failed(t, _nonEmpty(message));
  }
  if (before.loop?.phase == LoopPhase.running && after.loop == null && !after.run.running) {
    return (kind: NotificationKind.done, body: _doneBody(t, after, goalCompleted: false));
  }
  return null;
}

SessionAlert _failed(Translations t, String? message) =>
    (kind: NotificationKind.failed, body: _clip(message ?? t.notifications.runFailed, _bodyLength));

/// Whether [after]'s goal is complete and was not, as that goal, when the run began.
bool _completed(Goal? runStartGoal, SessionView after) => switch (after.goal) {
  Goal(status: GoalStatus.complete, :final id) => runStartGoal?.id != id || runStartGoal?.status != GoalStatus.complete,
  _ => false,
};

/// The title of a notification about [view] (docs/contracts/push.md, "Payload"): the session's name, else the first
/// line of its first user message ([firstMessage] from the machine's listing, else the transcript's), else the last
/// component of its working directory [cwd].
String alertTitle(SessionView view, {required String cwd, String? firstMessage}) {
  final name = _nonEmpty(view.config.sessionName);
  final line = name ?? _firstLine(firstMessage ?? firstUserMessage(view));
  return _clip(line ?? cwd.split(RegExp(r'[/\\]')).lastWhere((part) => part.isNotEmpty, orElse: () => cwd), 120);
}

const _bodyLength = 240;

bool _asks(UiRequest request) => switch (request) {
  SelectRequest() || ApprovalRequest() || ConfirmRequest() || InputRequest() || EditorRequest() => true,
  CompanionRequest(:final method) => method == 'ask',
  EditorTextRequest() || OpenUrlRequest() => false,
};

String _question(Translations t, UiRequest request) => switch (request) {
  ApprovalRequest(:final toolName) => t.notifications.approval(tool: toolName),
  SelectRequest(:final title) || ConfirmRequest(:final title) || InputRequest(:final title) => title,
  EditorRequest(:final title) => title,
  CompanionRequest(:final params) => switch (params['questions']) {
    [{'question': final String question}, ...] when question.trim().isNotEmpty => question.trim(),
    _ => t.ask.title,
  },
  EditorTextRequest() || OpenUrlRequest() => throw ArgumentError.value(request, 'request', 'asks nothing'),
};

/// An active goal continues after the run; so does a loop that is on, not suspended and has its prompt.
bool _continues(SessionView view) => view.goal?.status == GoalStatus.active || view.loop?.phase == LoopPhase.running;

String _doneBody(Translations t, SessionView view, {required bool goalCompleted}) {
  if (goalCompleted) return _clip(t.notifications.goalComplete(objective: view.goal!.objective), _bodyLength);
  for (var i = view.transcript.length - 1; i >= 0; i--) {
    if (view.transcript[i] case final AssistantItem reply) {
      return _clip(_firstLine(reply.text) ?? t.notifications.finished, _bodyLength);
    }
  }
  return t.notifications.finished;
}

String? _nonEmpty(String? text) => text == null || text.trim().isEmpty ? null : text.trim();

String? _firstLine(String? text) =>
    text?.split('\n').map((line) => line.trim()).where((line) => line.isNotEmpty).firstOrNull;

/// At most [length] characters, cut at a character boundary with `…`.
String _clip(String text, int length) {
  final characters = text.characters;
  return characters.length <= length ? text : '${characters.take(length - 1)}…';
}
