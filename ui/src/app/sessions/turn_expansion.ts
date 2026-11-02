// Port of lib/sessions/turn_expansion.dart.
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { TranscriptItem } from "../../core/store/transcript";

/**
 * Which settled turns of one session's chat the reader opened, and an entry whose turn the chat should open. Kept per
 * open session, so switching sessions and back keeps each chat's open turns.
 *
 * A turn is known by its first item: by the item's key, and by its session entry id once it has one, so a turn stays
 * open when a resync rebuilds the transcript with entry ids as keys.
 */
export class TurnExpansion {
  /** Bumped wherever the Dart ChangeNotifier notifies; the chat reacts to it. */
  readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private readonly open = new Set<string>();
  private revealing: string | undefined;
  private toEnd = false;

  constructor() {
    [this.changed, this.setChanged] = createSignal(0);
  }

  isOpen(head: TranscriptItem): boolean {
    return this.open.has(head.key) || (head.entryId !== undefined && this.open.has(head.entryId));
  }

  setOpen(head: TranscriptItem, open: boolean): void {
    this.set(head, open);
    this.notify();
  }

  /**
   * Asks the chat to open the turn holding the entry `entryId` once its transcript holds it: the tree navigated there.
   */
  reveal(entryId: string): void {
    this.revealing = entryId;
    this.notify();
  }

  /** The entry reveal asked for, until the chat found it. */
  get pendingReveal(): string | undefined {
    return this.revealing;
  }

  /**
   * The chat found the entry pendingReveal names in the turn that starts with `head`, and opens it. Does not notify:
   * the chat shows the change itself.
   */
  revealedIn(head: TranscriptItem): void {
    this.revealing = undefined;
    this.set(head, true);
  }

  /**
   * Asks the chat to show the end of the transcript once it has rebuilt: a tree navigation moved the leaf, so the kept
   * conversation is what the reader should now see.
   */
  jumpToEnd(): void {
    this.toEnd = true;
    this.notify();
  }

  /** Whether the chat should scroll to the end, once. */
  takeJumpToEnd(): boolean {
    const toEnd = this.toEnd;
    this.toEnd = false;
    return toEnd;
  }

  private notify(): void {
    this.setChanged((count) => count + 1);
  }

  private set(head: TranscriptItem, open: boolean): void {
    if (open) {
      this.open.add(head.key);
      if (head.entryId !== undefined) this.open.add(head.entryId);
    } else {
      this.open.delete(head.key);
      if (head.entryId !== undefined) this.open.delete(head.entryId);
    }
  }
}
