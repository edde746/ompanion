// lib/screens/settings/settings_pane.dart's `shortcutList`: the keyboard shortcuts the settings pane lists.
import { t } from "../../i18n/i18n";
import type { AppIntent, Shortcut } from "../shell/shortcuts";

/** What `shortcuts` do and their keys, in binding order; the panel-tab keys share one row (`⌘1–⌘5`). */
export function shortcutList(shortcuts: readonly Shortcut[], apple: boolean): [label: string, keys: string][] {
  const s = t.settings;
  const rows: [string, string][] = [];
  const tabKeys: string[] = [];
  for (const shortcut of shortcuts) {
    const label = intentLabel(shortcut.intent);
    if (label !== undefined) {
      rows.push([label, keys(shortcut, apple)]);
      continue;
    }
    if (tabKeys.length === 0) rows.push([s.shortcutPanelTab, ""]);
    tabKeys.push(keys(shortcut, apple));
  }
  const row = rows.find(([label]) => label === s.shortcutPanelTab);
  if (row) row[1] = tabKeys.length === 1 ? tabKeys[0]! : `${tabKeys[0]}–${tabKeys[tabKeys.length - 1]}`;
  return rows;
}

/** Undefined for a panel tab, whose keys share one row. */
function intentLabel(intent: AppIntent): string | undefined {
  const s = t.settings;
  switch (intent.kind) {
    case "ToggleSidebarIntent":
      return s.shortcutToggleSidebar;
    case "TogglePanelsIntent":
      return s.shortcutTogglePanels;
    case "ShowPanelTabIntent":
      return undefined;
    case "AddMachineIntent":
      return s.shortcutAddMachine;
    case "OpenSettingsIntent":
      return s.shortcutSettings;
    case "NewSessionIntent":
      return s.shortcutNewSession;
    case "TogglePauseIntent":
      return s.shortcutTogglePause;
    case "OpenPaletteIntent":
      return s.shortcutPalette;
    case "SearchSessionsIntent":
      return s.shortcutSearchSessions;
    case "AbortRunIntent":
      return s.shortcutAbort;
  }
}

/** `⇧⌘M` on Apple's platforms, `Ctrl+Shift+M` elsewhere. */
function keys(shortcut: Shortcut, apple: boolean): string {
  const key = shortcut.key === "escape" ? "Esc" : shortcut.key.toUpperCase();
  if (apple) return `${shortcut.shift ? "⇧" : ""}${shortcut.primary ? "⌘" : ""}${key}`;
  return [...(shortcut.primary ? ["Ctrl"] : []), ...(shortcut.shift ? ["Shift"] : []), key].join("+");
}
