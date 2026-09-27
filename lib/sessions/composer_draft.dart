import 'package:flutter/widgets.dart';

import 'composer_attachments.dart';
import 'message_mentions.dart';

/// A model the user tagged in the draft: one character of [ComposerText.text], shown as a chip with [name]. [source]
/// is what the character stands for in the message: omp's token `^provider/id`, or the `<model agent="m1" …/>` tag
/// omp wrote for it when a message it received comes back into the composer.
typedef ModelChip = ({String name, String source});

/// The composer's text. A tagged model is one character from Unicode's private use area, so the cursor, deleting and
/// selecting treat it as one unit, as omp's editor treats its chips; [chips] maps each such character.
class ComposerText extends TextEditingController {
  /// The chips by character. An entry outlives its character within one draft, so undo brings a deleted chip back.
  Map<String, ModelChip> chips = {};

  /// Draws a chip; the composer sets it. Without it a chip shows as its bare character.
  InlineSpan Function(ModelChip chip, TextStyle? style)? chipSpan;

  /// [value], a part of [text], with every chip written out as its source: the text omp receives.
  String expand(String value) =>
      chips.isEmpty ? value : value.replaceAllMapped(_chipCharacter, (match) => chips[match[0]]?.source ?? match[0]!);

  /// Puts [chip] and a space over [start]–[end] with the cursor after them, as omp's completion inserts
  /// `^provider/id `. A model whose name a chip in the draft already shows for another model goes in as its source,
  /// as in omp: two chips alike would hide which model is which.
  void insertChip(int start, int end, ModelChip chip) {
    final current = text;
    final lookalike = chips.entries.any(
      (entry) => entry.value.name == chip.name && entry.value.source != chip.source && current.contains(entry.key),
    );
    final String inserted;
    if (lookalike) {
      inserted = '${chip.source} ';
    } else {
      final character = _freeCharacter(current, chips);
      chips[character] = chip;
      inserted = '$character ';
    }
    value = TextEditingValue(
      text: current.replaceRange(start, end, inserted),
      selection: TextSelection.collapsed(offset: start + inserted.length),
    );
  }

  /// Replaces the text with [value], its `<model …/>` tags as chips, the cursor at the end. [kept] are chips whose
  /// characters [value] holds: the draft's own, for a text built from it.
  void setDraft(String value, {Map<String, ModelChip> kept = const {}}) {
    final next = Map.of(kept);
    final collapsed = value.replaceAllMapped(modelTag, (tag) {
      final character = _freeCharacter(value, next);
      next[character] = (name: tag[2]!, source: tag[0]!);
      return character;
    });
    chips = next;
    this.value = TextEditingValue(
      text: collapsed,
      selection: TextSelection.collapsed(offset: collapsed.length),
    );
  }

  @override
  void clear() {
    super.clear();
    chips = {};
  }

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    final span = super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    final draw = chipSpan;
    if (draw == null || chips.isEmpty || !_chipCharacter.hasMatch(text)) return span;
    return _withChips(span, style, draw);
  }

  TextSpan _withChips(TextSpan span, TextStyle? inherited, InlineSpan Function(ModelChip, TextStyle?) draw) {
    final style = inherited?.merge(span.style) ?? span.style;
    final children = <InlineSpan>[];
    span.text?.splitMapJoin(
      _chipCharacter,
      onMatch: (match) {
        final chip = chips[match[0]];
        children.add(chip == null ? TextSpan(text: match[0]) : draw(chip, style));
        return '';
      },
      onNonMatch: (plain) {
        if (plain.isNotEmpty) children.add(TextSpan(text: plain));
        return '';
      },
    );
    for (final child in span.children ?? const <InlineSpan>[]) {
      children.add(child is TextSpan ? _withChips(child, style, draw) : child);
    }
    return TextSpan(style: span.style, children: children);
  }
}

/// Unicode's private use area in the Basic Multilingual Plane: one UTF-16 unit per character, which a text field
/// lays out as one inline widget.
final _chipCharacter = RegExp('[\uE000-\uF8FF]');

/// The first private-use character neither in [text] nor already a chip.
String _freeCharacter(String text, Map<String, ModelChip> chips) {
  for (var code = 0xE000; code <= 0xF8FF; code++) {
    final character = String.fromCharCode(code);
    if (!chips.containsKey(character) && !text.contains(character)) return character;
  }
  throw StateError('No private-use character is left for another model chip.');
}

/// What the user is composing for one session: text and attachments. Kept per session, so switching sessions keeps
/// each composer's draft, and filled from outside by `set_editor_text`, branching and tree navigation, which put
/// text back into the editor as the TUI does.
class ComposerDraft extends ChangeNotifier {
  final ComposerText text = ComposerText();
  List<ComposerAttachment> _attachments = const [];
  bool _focusRequested = false;

  /// Set by [dispose]. A send, a paste or a file picker finishes after an await that may have outlived the session.
  bool _disposed = false;

  List<ComposerAttachment> get attachments => _attachments;

  /// Replaces text and attachments, puts the cursor at the end and asks the composer for focus. The `<model …/>` tags
  /// of a message omp received become chips again; [chips] are those a text from this draft holds.
  void replace(
    String value, {
    List<ComposerAttachment> attachments = const [],
    Map<String, ModelChip> chips = const {},
  }) {
    text.setDraft(value, kept: chips);
    _attachments = List.unmodifiable(attachments);
    _focusRequested = true;
    notifyListeners();
  }

  /// Puts back a prompt that did not go out, with its [chips], unless the session closed or the user started a new
  /// draft meanwhile.
  void giveBack(
    String value, {
    List<ComposerAttachment> attachments = const [],
    Map<String, ModelChip> chips = const {},
  }) {
    if (_disposed || text.text.trim().isNotEmpty || _attachments.isNotEmpty) return;
    replace(value, attachments: attachments, chips: chips);
  }

  /// Puts a message taken back from the queue ahead of the draft, as the TUI's dequeue does: the texts joined by a
  /// blank line, the queued attachments after the draft's.
  void restoreQueued(String value, {List<ComposerAttachment> attachments = const []}) => replace(
    [value, text.text].where((part) => part.trim().isNotEmpty).join('\n\n'),
    attachments: [..._attachments, ...attachments],
    chips: text.chips,
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
