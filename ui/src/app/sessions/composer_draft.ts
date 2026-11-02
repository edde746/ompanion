// Port of lib/sessions/composer_draft.dart.
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { ComposerAttachment, TextAttachment } from "./composer_attachments";
import { modelTag } from "./message_mentions";

/**
 * A model the user tagged in the draft: one character of ComposerText.text, shown as a chip with `name`. `source` is
 * what the character stands for in the message: omp's token `^provider/id`, or the `<model agent="m1" …/>` tag omp
 * wrote for it when a message it received comes back into the composer.
 */
export interface ModelChip {
  readonly name: string;
  readonly source: string;
}

/** A selection in UTF-16 units, `start` ≤ `end`; collapsed when they are equal (the cursor). */
export interface TextSelection {
  readonly start: number;
  readonly end: number;
}

/** Flutter's TextEditingValue: the text, and the selection while the field has one. */
export interface TextValue {
  readonly text: string;
  readonly selection?: TextSelection;
}

export function collapsedAt(offset: number): TextSelection {
  return { start: offset, end: offset };
}

/**
 * Unicode's private use area in the Basic Multilingual Plane: one UTF-16 unit per character, which the composer lays
 * out as one inline chip.
 */
export const chipCharacter = /[\uE000-\uF8FF]/g;

/** The first private-use character neither in `text` nor already a chip. */
function freeCharacter(text: string, chips: ReadonlyMap<string, ModelChip>): string {
  for (let code = 0xe000; code <= 0xf8ff; code++) {
    const character = String.fromCharCode(code);
    if (!chips.has(character) && !text.includes(character)) return character;
  }
  throw new Error("No private-use character is left for another model chip.");
}

/**
 * The composer's text. A tagged model is one character from Unicode's private use area, so the cursor, deleting and
 * selecting treat it as one unit, as omp's editor treats its chips; `chips` maps each such character.
 */
export class ComposerText {
  /** Bumped on every change of `value`; read it to follow the text. */
  readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private current: TextValue = { text: "" };

  /** The chips by character. An entry outlives its character within one draft, so undo brings a deleted chip back. */
  chips: Map<string, ModelChip> = new Map();

  constructor() {
    [this.changed, this.setChanged] = createSignal(0);
  }

  get value(): TextValue {
    return this.current;
  }

  set value(next: TextValue) {
    this.current = next;
    this.setChanged((count) => count + 1);
  }

  get text(): string {
    return this.current.text;
  }

  get selection(): TextSelection | undefined {
    return this.current.selection;
  }

  /** `value`, a part of `text`, with every chip written out as its source: the text omp receives. */
  expand(value: string): string {
    if (this.chips.size === 0) return value;
    return value.replace(chipCharacter, (character) => this.chips.get(character)?.source ?? character);
  }

  /**
   * Puts `chip` and a space over `start`–`end` with the cursor after them, as omp's completion inserts
   * `^provider/id `. A model whose name a chip in the draft already shows for another model goes in as its source, as
   * in omp: two chips alike would hide which model is which.
   */
  insertChip(start: number, end: number, chip: ModelChip): void {
    const current = this.text;
    let lookalike = false;
    for (const [character, other] of this.chips) {
      if (other.name === chip.name && other.source !== chip.source && current.includes(character)) lookalike = true;
    }
    let inserted: string;
    if (lookalike) {
      inserted = `${chip.source} `;
    } else {
      const character = freeCharacter(current, this.chips);
      this.chips.set(character, chip);
      inserted = `${character} `;
    }
    this.value = {
      text: current.substring(0, start) + inserted + current.substring(end),
      selection: collapsedAt(start + inserted.length),
    };
  }

  /**
   * Replaces the text with `value`, its `<model …/>` tags as chips, the cursor at the end. `kept` are chips whose
   * characters `value` holds: the draft's own, for a text built from it.
   */
  setDraft(value: string, options: { kept?: ReadonlyMap<string, ModelChip> } = {}): void {
    const next = new Map(options.kept);
    const collapsed = value.replace(modelTag, (tag: string, _agent: string, name: string) => {
      const character = freeCharacter(value, next);
      next.set(character, { name, source: tag });
      return character;
    });
    this.chips = next;
    this.value = { text: collapsed, selection: collapsedAt(collapsed.length) };
  }

  clear(): void {
    this.value = { text: "", selection: collapsedAt(0) };
    this.chips = new Map();
  }
}

/** A slash command's word at the start of a draft. */
const leadingCommand = /^\/\S*/;

/**
 * What the user is composing for one session: text and attachments. Kept per session, so switching sessions keeps
 * each composer's draft, and filled from outside by `set_editor_text`, branching and tree navigation, which put text
 * back into the editor as the TUI does.
 */
export class ComposerDraft {
  readonly text = new ComposerText();
  /** Bumped when the attachments change or the composer is asked for focus. */
  readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private list: readonly ComposerAttachment[] = [];
  private focusRequested = false;

  /** Set by dispose. A send, a paste or a file picker finishes after an await that may have outlived the session. */
  private disposed = false;

  constructor() {
    [this.changed, this.setChanged] = createSignal(0);
  }

  get attachments(): readonly ComposerAttachment[] {
    return this.list;
  }

  /**
   * Replaces text and attachments, puts the cursor at the end and asks the composer for focus. The `<model …/>` tags
   * of a message omp received become chips again; `chips` are those a text from this draft holds.
   */
  replace(
    value: string,
    options: { attachments?: readonly ComposerAttachment[]; chips?: ReadonlyMap<string, ModelChip> } = {},
  ): void {
    this.text.setDraft(value, { kept: options.chips });
    this.list = [...(options.attachments ?? [])];
    this.focusRequested = true;
    this.notify();
  }

  /**
   * Puts back a prompt that did not go out, with its `chips`, unless the session closed or the user started a new draft
   * meanwhile.
   */
  giveBack(
    value: string,
    options: { attachments?: readonly ComposerAttachment[]; chips?: ReadonlyMap<string, ModelChip> } = {},
  ): void {
    if (this.disposed || this.text.text.trim().length > 0 || this.list.length > 0) return;
    this.replace(value, options);
  }

  /**
   * Puts a message taken back from the queue ahead of the draft, as the TUI's dequeue does: the texts joined by a blank
   * line, the queued attachments after the draft's.
   */
  restoreQueued(value: string, options: { attachments?: readonly ComposerAttachment[] } = {}): void {
    this.replace(
      [value, this.text.text].filter((part) => part.trim().length > 0).join("\n\n"),
      { attachments: [...this.list, ...(options.attachments ?? [])], chips: this.text.chips },
    );
  }

  /** Starts a slash command unless the draft already has text, and asks the composer for focus. */
  openPalette(): void {
    if (this.text.text.length === 0) this.text.value = { text: "/", selection: collapsedAt(1) };
    this.requestFocus();
  }

  /**
   * Puts the slash command `name` at the start of the draft, in place of a slash command it starts with (the palette's
   * `/`, a typed `/goal`, a command picked before), and asks the composer for focus: the command's arguments come next,
   * the draft's other text among them.
   */
  startCommand(name: string): void {
    const rest = this.text.text.trimStart().replace(leadingCommand, "").trimStart();
    const value = `/${name} ${rest}`;
    this.text.value = { text: value, selection: collapsedAt(value.length) };
    this.requestFocus();
  }

  /** Asks the composer for focus, e.g. after a dialog closed, as the TUI returns to its editor. */
  requestFocus(): void {
    this.focusRequested = true;
    this.notify();
  }

  /**
   * Puts `value` over the selected text with the cursor after it, as a paste does; at the end while the field has no
   * selection.
   */
  insert(value: string): void {
    if (this.disposed) return;
    const { text, selection } = this.text.value;
    const start = selection?.start ?? text.length;
    const end = selection?.end ?? text.length;
    this.text.value = {
      text: text.substring(0, start) + value + text.substring(end),
      selection: collapsedAt(start + value.length),
    };
  }

  addAttachments(attachments: Iterable<ComposerAttachment>): void {
    if (this.disposed) return;
    this.list = [...this.list, ...attachments];
    this.notify();
  }

  removeAttachment(attachment: ComposerAttachment): void {
    const index = this.list.indexOf(attachment);
    if (this.disposed || index < 0) return;
    this.list = this.list.filter((_, at) => at !== index);
    this.notify();
  }

  /** Moves a pasted text out of its chip and into the text at the cursor ("Paste inline"), and asks for focus. */
  inline(attachment: TextAttachment): void {
    if (this.disposed) return;
    this.removeAttachment(attachment);
    this.insert(attachment.text);
    this.requestFocus();
  }

  clear(): void {
    this.text.clear();
    this.list = [];
    this.notify();
  }

  /** True once after a focus request; the composer takes focus when it sees it. */
  takeFocusRequest(): boolean {
    const requested = this.focusRequested;
    this.focusRequested = false;
    return requested;
  }

  dispose(): void {
    this.disposed = true;
  }

  private notify(): void {
    this.setChanged((count) => count + 1);
  }
}
