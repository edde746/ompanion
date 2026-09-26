import 'package:flutter/foundation.dart';
import 'package:omp_core/store.dart';

/// Which settled turns of one session's chat the reader opened, and an entry whose turn the chat should open. Kept
/// per open session, so switching sessions and back keeps each chat's open turns.
///
/// A turn is known by its first item: by the item's key, and by its session entry id once it has one, so a turn stays
/// open when a resync rebuilds the transcript with entry ids as keys.
class TurnExpansion extends ChangeNotifier {
  final _open = <String>{};
  String? _reveal;

  bool isOpen(TranscriptItem head) => _open.contains(head.key) || _open.contains(head.entryId);

  void setOpen(TranscriptItem head, bool open) {
    _set(head, open);
    notifyListeners();
  }

  /// Asks the chat to open the turn holding the entry [entryId] once its transcript holds it: the tree navigated
  /// there.
  void reveal(String entryId) {
    _reveal = entryId;
    notifyListeners();
  }

  /// The entry [reveal] asked for, until the chat found it.
  String? get pendingReveal => _reveal;

  /// The chat found the entry [pendingReveal] names in the turn that starts with [head], and opens it. Does not
  /// notify: the chat shows the change itself.
  void revealedIn(TranscriptItem head) {
    _reveal = null;
    _set(head, true);
  }

  void _set(TranscriptItem head, bool open) {
    if (open) {
      _open.add(head.key);
      if (head.entryId case final id?) _open.add(id);
    } else {
      _open
        ..remove(head.key)
        ..remove(head.entryId);
    }
  }
}
