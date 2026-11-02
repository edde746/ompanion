// Port of lib/terminal/terminal_deck.dart.
import type { Terminal } from "@xterm/xterm";
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { TerminalScreen, TerminalSession } from "./terminal_session";

/** The terminal tabs of one machine. Outlives the dock's views, so closing the dock keeps the shells. */
export class TerminalDeck<T extends TerminalScreen = Terminal> {
  /** Bumped on every change of the tabs or the selection; a tab's own title and phase follow its `changed`. */
  readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private readonly list: TerminalSession<T>[] = [];
  private selected = 0;

  constructor() {
    [this.changed, this.setChanged] = createSignal(0);
  }

  get sessions(): readonly TerminalSession<T>[] {
    return [...this.list];
  }

  get current(): TerminalSession<T> | undefined {
    return this.list[this.selected];
  }

  get selectedIndex(): number {
    return this.selected;
  }

  add(session: TerminalSession<T>): void {
    this.list.push(session);
    this.selected = this.list.length - 1;
    this.notify();
  }

  select(index: number): void {
    if (index < 0 || index >= this.list.length || index === this.selected) return;
    this.selected = index;
    this.notify();
  }

  /** Ends [session]'s shell and removes its tab. */
  close(session: TerminalSession<T>): void {
    const index = this.list.indexOf(session);
    if (index < 0) return;
    this.list.splice(index, 1);
    session.dispose();
    if (index < this.selected) this.selected--;
    if (this.selected >= this.list.length) this.selected = Math.max(0, this.list.length - 1);
    this.notify();
  }

  /** Ends every shell. */
  dispose(): void {
    for (const session of this.list.splice(0)) session.dispose();
  }

  private notify(): void {
    this.setChanged((value) => value + 1);
  }
}
