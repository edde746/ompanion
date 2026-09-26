import 'package:flutter/widgets.dart';

import 'composer_attachments.dart';

/// What the user is composing for one session: text and attachments. Kept per session, so switching sessions keeps
/// each composer's draft, and filled from outside by `set_editor_text`, branching and tree navigation, which put
/// text back into the editor as the TUI does.
class ComposerDraft extends ChangeNotifier {
  final TextEditingController text = TextEditingController();
  List<ComposerAttachment> _attachments = const [];
  bool _focusRequested = false;

  /// Set by [dispose]. A send, a paste or a file picker finishes after an await that may have outlived the session.
  bool _disposed = false;

  List<ComposerAttachment> get attachments => _attachments;

  /// Replaces text and attachments, puts the cursor at the end and asks the composer for focus.
  void replace(String value, {List<ComposerAttachment> attachments = const []}) {
    text.value = TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length));
    _attachments = List.unmodifiable(attachments);
    _focusRequested = true;
    notifyListeners();
  }

  /// Puts back a prompt that did not go out, unless the session closed or the user started a new draft meanwhile.
  void giveBack(String value, {List<ComposerAttachment> attachments = const []}) {
    if (_disposed || text.text.trim().isNotEmpty || _attachments.isNotEmpty) return;
    replace(value, attachments: attachments);
  }

  /// Puts a message taken back from the queue ahead of the draft, as the TUI's dequeue does: the texts joined by a
  /// blank line, the queued attachments after the draft's.
  void restoreQueued(String value, {List<ComposerAttachment> attachments = const []}) => replace(
    [value, text.text].where((part) => part.trim().isNotEmpty).join('\n\n'),
    attachments: [..._attachments, ...attachments],
  );

  /// Starts a slash command unless the draft already has text, and asks the composer for focus.
  void openPalette() {
    if (text.text.isEmpty) {
      text.value = const TextEditingValue(text: '/', selection: TextSelection.collapsed(offset: 1));
    }
    _focusRequested = true;
    notifyListeners();
  }

  /// Asks the composer for focus, e.g. after a dialog closed, as the TUI returns to its editor.
  void requestFocus() {
    _focusRequested = true;
    notifyListeners();
  }

  /// Puts [value] over the selected text with the cursor after it, as a paste does; at the end while the field has
  /// no selection.
  void insert(String value) {
    if (_disposed) return;
    final current = text.value;
    final selection = current.selection.isValid
        ? current.selection
        : TextSelection.collapsed(offset: current.text.length);
    text.value = TextEditingValue(
      text: current.text.replaceRange(selection.start, selection.end, value),
      selection: TextSelection.collapsed(offset: selection.start + value.length),
    );
  }

  void addAttachments(Iterable<ComposerAttachment> attachments) {
    if (_disposed) return;
    _attachments = List.unmodifiable([..._attachments, ...attachments]);
    notifyListeners();
  }

  void removeAttachment(ComposerAttachment attachment) {
    final index = _attachments.indexOf(attachment);
    if (_disposed || index < 0) return;
    _attachments = List.unmodifiable([..._attachments]..removeAt(index));
    notifyListeners();
  }

  /// Moves a pasted text out of its chip and into the text at the cursor ("Paste inline"), and asks for focus.
  void inline(TextAttachment attachment) {
    if (_disposed) return;
    removeAttachment(attachment);
    insert(attachment.text);
    requestFocus();
  }

  void clear() {
    text.clear();
    _attachments = const [];
    notifyListeners();
  }

  /// True once after [replace]; the composer takes focus when it sees it.
  bool takeFocusRequest() {
    final requested = _focusRequested;
    _focusRequested = false;
    return requested;
  }

  @override
  void dispose() {
    _disposed = true;
    text.dispose();
    super.dispose();
  }
}
