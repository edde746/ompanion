import { expect, test } from "bun:test";
import { t } from "../../i18n/i18n";
import { appShortcuts } from "../shell/shortcuts";
import { shortcutList } from "./shortcut_list";

test("every app shortcut is listed once, the panel tabs as one range", () => {
  const s = t.settings;
  const mac = shortcutList(appShortcuts(), true);
  expect(mac).toContainEqual([s.shortcutToggleSidebar, "⌘B"]);
  expect(mac).toContainEqual([s.shortcutPanelTab, "⌘1–⌘5"]);
  expect(mac).toContainEqual([s.shortcutAddMachine, "⇧⌘M"]);
  expect(mac).toContainEqual([s.shortcutAbort, "Esc"]);
  expect(mac).toContainEqual([s.shortcutSearchSessions, "⌘F"]);
  expect(new Set(mac.map(([label]) => label)).size).toBe(mac.length);
  expect(mac).toHaveLength(appShortcuts().length - 4);

  const linux = shortcutList(appShortcuts(), false);
  expect(linux).toContainEqual([s.shortcutSettings, "Ctrl+,"]);
  expect(linux).toContainEqual([s.shortcutTogglePause, "Ctrl+Shift+P"]);
});
