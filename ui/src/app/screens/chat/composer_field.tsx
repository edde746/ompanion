// The composer's text field: Flutter's TextField over ComposerText (lib/sessions/composer_draft.dart), whose
// buildTextSpan draws each model chip inline. The web has no text input that lays out an element inside its text, so
// the field is a plain-text contenteditable: text nodes for the text, one non-editable element per chip. The draft is
// the truth: every input and caret move is read back into it, and a change from elsewhere (a picked model or command,
// a paste, a draft put back) renders the field anew from it.
import { createEffect, createMemo, createRoot, getOwner, onSettled, runWithOwner, untrack } from "solid-js";
import { type ComposerDraft, type TextSelection, type TextValue } from "../../sessions/composer_draft";
import { modelChipSpan } from "./mention_spans";
import "./composer_field.css";

/** The attribute holding a chip element's character. */
const chipAttribute = "data-chip";

export interface ComposerFieldHandle {
  readonly element: HTMLElement;
  /** Focuses the field with the caret where the draft's selection is (at the end without one). */
  focus(): void;
  /** Reads the field's text and caret into the draft, for an action that is about to use them. */
  sync(): void;
}

export interface ComposerFieldProps {
  readonly draft: ComposerDraft;
  readonly placeholder: string;
  /** Before the field's own handling; `preventDefault` keeps a key from the text. */
  readonly onKeyDown: (event: KeyboardEvent) => void;
  readonly onPaste: (event: ClipboardEvent) => void;
  readonly ref: (handle: ComposerFieldHandle) => void;
}

function isChip(node: Node): node is HTMLElement {
  return node instanceof HTMLElement && node.hasAttribute(chipAttribute);
}

/** The `<br>` a text ending in a new line needs after it, so the field shows the empty last line. */
function isEndMark(root: HTMLElement, node: Node): boolean {
  return node instanceof HTMLBRElement && node === root.lastChild;
}

/** The units of `root` in order, each with the length it has in the draft's text. */
function* units(root: HTMLElement, node: Node = root): Generator<{ node: Node; length: number }> {
  for (const child of Array.from(node.childNodes)) {
    if (child instanceof Text) yield { node: child, length: child.data.length };
    else if (isChip(child)) yield { node: child, length: 1 };
    else if (child instanceof HTMLBRElement) yield { node: child, length: isEndMark(root, child) ? 0 : 1 };
    else yield* units(root, child);
  }
}

function serialize(root: HTMLElement): string {
  let text = "";
  for (const { node, length } of units(root)) {
    if (node instanceof Text) text += node.data;
    else if (isChip(node)) text += node.getAttribute(chipAttribute) ?? "";
    else if (length > 0) text += "\n";
  }
  return text;
}

/** The draft's offset of the DOM point (`node`, `offset`) in `root`. */
function offsetOf(root: HTMLElement, node: Node, offset: number): number {
  // A point inside a chip is before it, or after it past its start.
  const chip = node instanceof Element ? node.closest(`[${chipAttribute}]`) : node.parentElement?.closest(`[${chipAttribute}]`);
  if (chip && root.contains(chip)) {
    const parent = chip.parentNode!;
    return offsetOf(root, parent, Array.prototype.indexOf.call(parent.childNodes, chip) + (offset > 0 ? 1 : 0));
  }
  let count = 0;
  if (node instanceof Text) {
    for (const unit of units(root)) {
      if (unit.node === node) return count + offset;
      count += unit.length;
    }
    return count;
  }
  // An element point is before its child at `offset`: the units inside the children before it come first.
  const before = Array.from(node.childNodes).slice(0, offset);
  for (const unit of units(root)) {
    if (!before.some((child) => child === unit.node || child.contains(unit.node))) {
      if (node === root || node.contains(unit.node)) return count;
      continue;
    }
    count += unit.length;
  }
  return count;
}

/** The DOM point at the draft's `offset`: inside a text node where there is one, else before a chip or line break. */
function pointAt(root: HTMLElement, offset: number): { node: Node; offset: number } {
  let count = 0;
  for (const unit of units(root)) {
    if (unit.node instanceof Text && offset <= count + unit.length) return { node: unit.node, offset: offset - count };
    if (!(unit.node instanceof Text) && offset === count) {
      const parent = unit.node.parentNode!;
      return { node: parent, offset: Array.prototype.indexOf.call(parent.childNodes, unit.node) };
    }
    count += unit.length;
  }
  const end = root.lastChild !== null && isEndMark(root, root.lastChild) ? root.childNodes.length - 1 : root.childNodes.length;
  return { node: root, offset: end };
}

export function ComposerField(props: ComposerFieldProps) {
  let root!: HTMLDivElement;
  let disposeChips: (() => void) | undefined;
  // The composer builds a field per draft.
  const draft = untrack(() => props.draft);
  // The chips' elements are built in an effect, which has no owner of its own.
  const owner = getOwner();
  const empty = createMemo(() => {
    draft.text.changed();
    return draft.text.text.length === 0;
  });

  /** The field's selection in the draft's offsets, or undefined while it is outside the field. */
  function selection(): TextSelection | undefined {
    const current = document.getSelection();
    if (!current || current.rangeCount === 0 || !root.contains(current.anchorNode)) return undefined;
    const range = current.getRangeAt(0);
    return {
      start: offsetOf(root, range.startContainer, range.startOffset),
      end: offsetOf(root, range.endContainer, range.endOffset),
    };
  }

  function sync() {
    const text = serialize(root);
    const current = draft.text.value;
    const at = selection() ?? current.selection;
    if (text === current.text && at?.start === current.selection?.start && at?.end === current.selection?.end) return;
    draft.text.value = at === undefined ? { text } : { text, selection: at };
  }

  function render(value: TextValue) {
    disposeChips?.();
    const chips = draft.text.chips;
    const nodes = runWithOwner(owner, () =>
      createRoot((dispose) => {
        disposeChips = dispose;
        const built: Node[] = [];
        let plain = "";
        for (const character of value.text) {
          const chip = character >= "\uE000" && character <= "\uF8FF" ? chips.get(character) : undefined;
          if (chip === undefined) {
            plain += character;
            continue;
          }
          if (plain.length > 0) built.push(document.createTextNode(plain));
          plain = "";
          const element = document.createElement("span");
          element.className = "composer-field-chip";
          element.contentEditable = "false";
          element.setAttribute(chipAttribute, character);
          element.append(modelChipSpan(chip.name) as Node);
          built.push(element);
        }
        if (plain.length > 0) built.push(document.createTextNode(plain));
        if (value.text.endsWith("\n")) built.push(document.createElement("br"));
        return built;
      }),
    );
    root.replaceChildren(...(nodes ?? []));
  }

  function place(at: TextSelection | undefined) {
    const current = document.getSelection();
    if (!current) return;
    const length = draft.text.text.length;
    const start = pointAt(root, at?.start ?? length);
    const end = pointAt(root, at?.end ?? length);
    current.setBaseAndExtent(start.node, start.offset, end.node, end.offset);
  }

  function focus() {
    root.focus({ preventScroll: true });
    place(draft.text.selection);
  }

  // A change that did not come from the field renders it anew; the caret follows while the field has the focus.
  createEffect(
    () => {
      draft.text.changed();
      return draft.text.value;
    },
    (value) => {
      if (serialize(root) === value.text) return;
      render(value);
      if (document.activeElement === root) place(value.selection);
    },
  );

  untrack(() => props.ref)({
    get element() {
      return root;
    },
    focus,
    sync,
  });

  onSettled(() => {
    const onSelectionChange = () => {
      if (document.activeElement === root) sync();
    };
    document.addEventListener("selectionchange", onSelectionChange);
    return () => {
      document.removeEventListener("selectionchange", onSelectionChange);
      disposeChips?.();
    };
  });

  function insert(text: string) {
    sync();
    draft.insert(text);
  }

  return (
    <div
      ref={root}
      class={["composer-field", { "composer-field-empty": empty() }]}
      contenteditable="plaintext-only"
      role="textbox"
      aria-multiline="true"
      aria-label={props.placeholder}
      data-placeholder={props.placeholder}
      onInput={() => sync()}
      onKeyDown={(event) => props.onKeyDown(event)}
      onBeforeInput={(event) => {
        // A new line goes in through the draft, so the field never holds a browser's own line break markup.
        if (event.inputType !== "insertParagraph" && event.inputType !== "insertLineBreak") return;
        event.preventDefault();
        insert("\n");
      }}
      onPaste={(event) => props.onPaste(event)}
      onCopy={(event) => copyChips(event, false)}
      onCut={(event) => copyChips(event, true)}
      onDrop={(event) => {
        // Dropped files go to the chat's drop target; dropped text is a paste at the drop point.
        if (event.dataTransfer?.types.includes("Files")) event.preventDefault();
      }}
    />
  );

  /**
   * Copies a selection holding a model chip as the text omp would receive; `cut` deletes it too. A selection without
   * one takes the field's own copy.
   */
  function copyChips(event: ClipboardEvent, cut: boolean) {
    sync();
    const at = props.draft.text.selection;
    if (at === undefined || at.start === at.end || !event.clipboardData) return;
    const text = props.draft.text.text;
    const selected = text.substring(at.start, at.end);
    const expanded = props.draft.text.expand(selected);
    if (expanded === selected) return;
    event.preventDefault();
    event.clipboardData.setData("text/plain", expanded);
    if (!cut) return;
    props.draft.text.value = {
      text: text.substring(0, at.start) + text.substring(at.end),
      selection: { start: at.start, end: at.start },
    };
  }
}
