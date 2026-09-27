import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/sessions/composer_draft.dart';

const _think = (name: 'Fake Think', source: '^fake/fake-think');

/// [text] typed with the cursor at its end.
ComposerText _typed(String text) => ComposerText()
  ..value = TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
  );

void main() {
  test('a picked model is one character that sends its selector, followed by a space and the cursor', () {
    final text = _typed('Have ^thi');
    text.insertChip(5, 9, _think);
    expect(text.text, hasLength(7), reason: 'Have + chip + space');
    expect(text.selection, const TextSelection.collapsed(offset: 7));
    text.value = TextEditingValue(text: '${text.text}review this change');
    expect(text.expand(text.text), 'Have ^fake/fake-think review this change');

    // Deleting the chip's one character deletes the whole mention.
    text.value = TextEditingValue(text: text.text.replaceRange(5, 6, ''));
    expect(text.expand(text.text), 'Have  review this change');
  });

  test('a second model with a name a chip already shows goes in as its selector; the same model is a chip again', () {
    final text = _typed('^');
    text.insertChip(0, 1, _think);
    text.value = TextEditingValue(
      text: '${text.text}^',
      selection: TextSelection.collapsed(offset: text.text.length + 1),
    );
    text.insertChip(text.text.length - 1, text.text.length, (name: 'Fake Think', source: '^other/fake-think'));
    expect(text.text.substring(2), '^other/fake-think ');

    text.value = TextEditingValue(
      text: '${text.text}^',
      selection: TextSelection.collapsed(offset: text.text.length + 1),
    );
    text.insertChip(text.text.length - 1, text.text.length, _think);
    expect(text.expand(text.text), '^fake/fake-think ^other/fake-think ^fake/fake-think ');
    expect(text.text, hasLength(2 + 18 + 2));
  });

  test("a message omp received comes back with its model tags as chips that send the tag as it was", () {
    final draft = ComposerDraft();
    addTearDown(draft.dispose);
    const received = 'Have <model agent="m1" name="Fake Think"/> review <model agent="m2" name="Fake One"/> too';
    draft.replace(received);
    expect(draft.text.text, hasLength('Have '.length + 1 + ' review '.length + 1 + ' too'.length));
    expect([for (final chip in draft.text.chips.values) chip.name], ['Fake Think', 'Fake One']);
    expect(draft.text.expand(draft.text.text), received);
  });

  test('a send that did not go out comes back with its chips; a queued message joins the draft with them', () {
    final draft = ComposerDraft();
    addTearDown(draft.dispose);
    draft.text.value = const TextEditingValue(text: 'ask ^', selection: TextSelection.collapsed(offset: 5));
    draft.text.insertChip(4, 5, _think);
    final typed = draft.text.text;
    final chips = draft.text.chips;
    draft.clear();
    expect(draft.text.chips, isEmpty);
    draft.giveBack(typed, chips: chips);
    expect(draft.text.expand(draft.text.text), 'ask ^fake/fake-think ');

    draft.restoreQueued('queued for <model agent="m1" name="Fake One"/>');
    expect(
      draft.text.expand(draft.text.text),
      'queued for <model agent="m1" name="Fake One"/>\n\nask ^fake/fake-think ',
      reason: 'both chips keep their own sources',
    );
    expect(draft.text.chips.values.map((chip) => chip.name).toSet(), {'Fake Think', 'Fake One'});
  });

  test('a private-use character that is no chip, e.g. a pasted icon glyph, stays as it is', () {
    final text = _typed('\uE000 icon');
    text.value = TextEditingValue(
      text: '${text.text} ^',
      selection: TextSelection.collapsed(offset: text.text.length + 2),
    );
    text.insertChip(text.text.length - 1, text.text.length, _think);
    expect(text.expand(text.text), '\uE000 icon ^fake/fake-think ');
  });
}
