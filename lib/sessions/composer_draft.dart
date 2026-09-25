import 'package:flutter/widgets.dart';
import 'package:omp_core/rpc.dart';

/// What the user is composing for one session: text and attached images. Kept per session, so switching
/// sessions keeps each composer's draft, and filled from outside by `set_editor_text`, branching and tree
/// navigation, which put text back into the editor as the TUI does.
class ComposerDraft extends ChangeNotifier {
  final TextEditingController text = TextEditingController();
  List<RpcImage> _images = const [];
  bool _focusRequested = false;

  List<RpcImage> get images => _images;

  /// Replaces text and images, puts the cursor at the end and asks the composer for focus.
  void replace(String value, {List<RpcImage> images = const []}) {
    text.value = TextEditingValue(text: value, selection: TextSelection.collapsed(offset: value.length));
    _images = List.unmodifiable(images);
    _focusRequested = true;
    notifyListeners();
  }

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

  void addImages(Iterable<RpcImage> images) {
    _images = List.unmodifiable([..._images, ...images]);
    notifyListeners();
  }

  void removeImageAt(int index) {
    _images = List.unmodifiable([..._images]..removeAt(index));
    notifyListeners();
  }

  void clear() {
    text.clear();
    _images = const [];
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
    text.dispose();
    super.dispose();
  }
}
