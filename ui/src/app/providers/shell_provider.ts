// lib/providers/shell_provider.dart: where the user is.
import { type Accessor, createSignal } from "solid-js";

/** What the center pane (wide) or the pushed page (narrow) shows. */
export type ShellSelection =
  | { readonly kind: "HomeSelection" }
  | { readonly kind: "MachineSelection"; readonly machineId: string }
  | { readonly kind: "KeysSelection" }
  /** Provider usage of every machine's accounts. */
  | { readonly kind: "UsageSelection" }
  | { readonly kind: "SettingsSelection" }
  /** The chat of `SessionsProvider.active`. */
  | { readonly kind: "SessionSelection" };

export const homeSelection: ShellSelection = { kind: "HomeSelection" };

export function shellSelectionEquals(a: ShellSelection, b: ShellSelection): boolean {
  if (a.kind === "MachineSelection" && b.kind === "MachineSelection") return a.machineId === b.machineId;
  return a.kind === b.kind;
}

/**
 * Navigation state shared by the wide and the narrow layout, so resizing the window keeps the place.
 *
 * The user's last choice of place wins. A navigation that finishes later, such as a session that takes a while to
 * open, takes a turn ({@link takeTurn}) when the user asks for it and shows its result only while {@link isLatest}
 * holds for that turn. Every {@link select} takes a turn too, so any later click supersedes it.
 */
export class ShellProvider {
  readonly selection: Accessor<ShellSelection>;
  /** Narrow layout only: the dock panels shown as their own page. */
  readonly panelsPageOpen: Accessor<boolean>;
  private readonly setSelection: (selection: ShellSelection) => void;
  private readonly setPanelsPage: (open: boolean) => void;
  private turn = 0;

  constructor() {
    const [selection, setSelection] = createSignal<ShellSelection>(homeSelection, { equals: shellSelectionEquals });
    const [panelsPageOpen, setPanelsPage] = createSignal(false);
    this.selection = selection;
    this.panelsPageOpen = panelsPageOpen;
    this.setSelection = setSelection;
    this.setPanelsPage = setPanelsPage;
  }

  /** Starts a navigation that finishes later; see {@link isLatest}. */
  takeTurn(): number {
    return ++this.turn;
  }

  /** Whether no navigation started since the one that took `turn`. */
  isLatest(turn: number): boolean {
    return turn === this.turn;
  }

  select(selection: ShellSelection): void {
    this.turn++;
    this.setSelection(selection);
  }

  setPanelsPageOpen(open: boolean): void {
    this.setPanelsPage(open);
  }
}
