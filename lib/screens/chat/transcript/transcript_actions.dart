import 'package:flutter/widgets.dart';

/// What the transcript asks of the screen that shows it. Null callbacks hide their affordance (a subagent's transcript
/// cannot be branched, a fully seeded one has nothing earlier to load).
final class TranscriptActions {
  const TranscriptActions({
    this.onBranchFrom,
    required this.onCopy,
    required this.onOpenFile,
    required this.onOpenSubagent,
    this.onLoadEarlier,
  });

  /// Branch the session from the user message with this session entry id.
  final void Function(String entryId)? onBranchFrom;

  /// Put [text] on the clipboard (and confirm it).
  final void Function(String text) onCopy;

  /// Show a file of the session's machine, optionally at a 1-based [line].
  final void Function(String path, {int? line}) onOpenFile;

  /// Show a task subagent by its id.
  final void Function(String id) onOpenSubagent;

  /// Load the page of history before the oldest row; completes when the view holds it.
  final Future<void> Function()? onLoadEarlier;
}

/// Hands [TranscriptActions] down to the rows. Rows read it when the user acts, not while building, so a screen that
/// passes new callbacks on every build does not rebuild the transcript.
class TranscriptScope extends InheritedWidget {
  const TranscriptScope({super.key, required this.actions, required super.child});

  final TranscriptActions actions;

  static TranscriptActions of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<TranscriptScope>();
    assert(scope != null, 'No TranscriptScope above this transcript row');
    return scope!.actions;
  }

  @override
  bool updateShouldNotify(TranscriptScope oldWidget) => false;
}
