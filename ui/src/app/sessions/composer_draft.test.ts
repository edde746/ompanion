// Port of test/sessions/composer_draft_test.dart.
import { expect, test } from "bun:test";
import { ComposerDraft, ComposerText, collapsedAt } from "./composer_draft";

const think = { name: "Fake Think", source: "^fake/fake-think" };

/** `text` typed with the cursor at its end. */
function typed(text: string): ComposerText {
  const composer = new ComposerText();
  composer.value = { text, selection: collapsedAt(text.length) };
  return composer;
}

test("a picked model is one character that sends its selector, followed by a space and the cursor", () => {
  const text = typed("Have ^thi");
  text.insertChip(5, 9, think);
  expect(text.text).toHaveLength(7);
  expect(text.selection).toEqual(collapsedAt(7));
  text.value = { text: `${text.text}review this change` };
  expect(text.expand(text.text)).toBe("Have ^fake/fake-think review this change");

  // Deleting the chip's one character deletes the whole mention.
  text.value = { text: text.text.substring(0, 5) + text.text.substring(6) };
  expect(text.expand(text.text)).toBe("Have  review this change");
});

test("a second model with a name a chip already shows goes in as its selector; the same model is a chip again", () => {
  const text = typed("^");
  text.insertChip(0, 1, think);
  text.value = { text: `${text.text}^`, selection: collapsedAt(text.text.length + 1) };
  text.insertChip(text.text.length - 1, text.text.length, { name: "Fake Think", source: "^other/fake-think" });
  expect(text.text.substring(2)).toBe("^other/fake-think ");

  text.value = { text: `${text.text}^`, selection: collapsedAt(text.text.length + 1) };
  text.insertChip(text.text.length - 1, text.text.length, think);
  expect(text.expand(text.text)).toBe("^fake/fake-think ^other/fake-think ^fake/fake-think ");
  expect(text.text).toHaveLength(2 + 18 + 2);
});

test("a message omp received comes back with its model tags as chips that send the tag as it was", () => {
  const draft = new ComposerDraft();
  const received = 'Have <model agent="m1" name="Fake Think"/> review <model agent="m2" name="Fake One"/> too';
  draft.replace(received);
  expect(draft.text.text).toHaveLength("Have ".length + 1 + " review ".length + 1 + " too".length);
  expect([...draft.text.chips.values()].map((chip) => chip.name)).toEqual(["Fake Think", "Fake One"]);
  expect(draft.text.expand(draft.text.text)).toBe(received);
  draft.dispose();
});

test("a send that did not go out comes back with its chips; a queued message joins the draft with them", () => {
  const draft = new ComposerDraft();
  draft.text.value = { text: "ask ^", selection: collapsedAt(5) };
  draft.text.insertChip(4, 5, think);
  const sent = draft.text.text;
  const chips = draft.text.chips;
  draft.clear();
  expect(draft.text.chips.size).toBe(0);
  draft.giveBack(sent, { chips });
  expect(draft.text.expand(draft.text.text)).toBe("ask ^fake/fake-think ");

  draft.restoreQueued('queued for <model agent="m1" name="Fake One"/>');
  // Both chips keep their own sources.
  expect(draft.text.expand(draft.text.text)).toBe(
    'queued for <model agent="m1" name="Fake One"/>\n\nask ^fake/fake-think ',
  );
  expect(new Set([...draft.text.chips.values()].map((chip) => chip.name))).toEqual(new Set(["Fake Think", "Fake One"]));
  draft.dispose();
});

test("a picked command takes the place of the command the draft starts with and keeps the text after it", () => {
  const draft = new ComposerDraft();
  const start = (text: string, name: string) => {
    draft.text.value = { text, selection: collapsedAt(text.length) };
    draft.startCommand(name);
    expect(draft.text.selection).toEqual(collapsedAt(draft.text.text.length));
    return draft.text.text;
  };

  draft.openPalette();
  draft.startCommand("goal");
  // The palette's slash is no objective.
  expect(draft.text.text).toBe("/goal ");
  expect(start("/goal", "goal")).toBe("/goal ");
  // A loop whose body is /goal would open the objective editor.
  expect(start("/goal ", "loop")).toBe("/loop ");
  expect(start("/goal ship it", "loop")).toBe("/loop ship it");
  expect(start("  write the tests", "goal")).toBe("/goal write the tests");
  draft.dispose();
});

test("a private-use character that is no chip, e.g. a pasted icon glyph, stays as it is", () => {
  const text = typed("\uE000 icon");
  text.value = { text: `${text.text} ^`, selection: collapsedAt(text.text.length + 2) };
  text.insertChip(text.text.length - 1, text.text.length, think);
  expect(text.expand(text.text)).toBe("\uE000 icon ^fake/fake-think ");
});
