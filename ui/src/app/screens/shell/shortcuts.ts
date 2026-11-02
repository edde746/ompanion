// lib/screens/shell/shortcuts.dart: the app-wide key bindings, Cmd on Apple's platforms and Ctrl elsewhere.
import { type DockTab, dockTabs } from "../../models/dock_tab";

export type AppIntent =
  | { readonly kind: "ToggleSidebarIntent" }
  | { readonly kind: "TogglePanelsIntent" }
  | { readonly kind: "ShowPanelTabIntent"; readonly tab: DockTab }
  | { readonly kind: "AddMachineIntent" }
  | { readonly kind: "OpenSettingsIntent" }
  | { readonly kind: "NewSessionIntent" }
  /** Pause or resume the shown session (companion `pause.set`). */
  | { readonly kind: "TogglePauseIntent" }
  /** Open the composer's command palette. */
  | { readonly kind: "OpenPaletteIntent" }
  /** Focus the sidebar's session search. */
  | { readonly kind: "SearchSessionsIntent" }
  /** Abort the shown session's run, as Esc does in the TUI. */
  | { readonly kind: "AbortRunIntent" };

/** A key with exactly these modifiers, as Flutter's SingleActivator: `primary` is Cmd on Apple, else Ctrl. */
export interface Shortcut {
  /** `KeyboardEvent.key`, lower case. */
  readonly key: string;
  readonly primary: boolean;
  readonly shift: boolean;
  readonly intent: AppIntent;
}

export function appShortcuts(): readonly Shortcut[] {
  const primary = (key: string, intent: AppIntent, shift = false): Shortcut => ({ key, primary: true, shift, intent });
  return [
    primary("b", { kind: "ToggleSidebarIntent" }),
    primary("j", { kind: "TogglePanelsIntent" }),
    ...dockTabs.map((tab, index) => primary(String(index + 1), { kind: "ShowPanelTabIntent", tab })),
    primary("m", { kind: "AddMachineIntent" }, true),
    primary(",", { kind: "OpenSettingsIntent" }),
    primary("n", { kind: "NewSessionIntent" }),
    primary("p", { kind: "TogglePauseIntent" }, true),
    primary("k", { kind: "OpenPaletteIntent" }),
    primary("f", { kind: "SearchSessionsIntent" }),
    { key: "escape", primary: false, shift: false, intent: { kind: "AbortRunIntent" } },
  ];
}

/** The intent `event` triggers, or null. `apple`: Cmd is the primary modifier, else Ctrl. */
export function shortcutIntent(
  shortcuts: readonly Shortcut[],
  event: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "shiftKey" | "altKey">,
  apple: boolean,
): AppIntent | null {
  if (event.altKey) return null;
  const primaryDown = apple ? event.metaKey : event.ctrlKey;
  const otherDown = apple ? event.ctrlKey : event.metaKey;
  if (otherDown) return null;
  const key = event.key.toLowerCase();
  const match = shortcuts.find(
    (shortcut) => shortcut.key === key && shortcut.primary === primaryDown && shortcut.shift === event.shiftKey,
  );
  return match?.intent ?? null;
}
