import { expect, test } from "bun:test";
import { appShortcuts, shortcutIntent } from "./shortcuts";

const key = (key: string, modifiers: { meta?: boolean; ctrl?: boolean; shift?: boolean; alt?: boolean } = {}) => ({
  key,
  metaKey: modifiers.meta ?? false,
  ctrlKey: modifiers.ctrl ?? false,
  shiftKey: modifiers.shift ?? false,
  altKey: modifiers.alt ?? false,
});

test("Cmd on Apple's platforms and Ctrl elsewhere, with exactly the shortcut's modifiers", () => {
  const shortcuts = appShortcuts();
  expect(shortcutIntent(shortcuts, key("b", { meta: true }), true)).toEqual({ kind: "ToggleSidebarIntent" });
  expect(shortcutIntent(shortcuts, key("b", { ctrl: true }), false)).toEqual({ kind: "ToggleSidebarIntent" });
  expect(shortcutIntent(shortcuts, key("b", { ctrl: true }), true)).toBeNull();
  expect(shortcutIntent(shortcuts, key("b", { meta: true, ctrl: true }), true)).toBeNull();
  expect(shortcutIntent(shortcuts, key("b", { meta: true, shift: true }), true)).toBeNull();
  expect(shortcutIntent(shortcuts, key("M", { meta: true, shift: true }), true)).toEqual({ kind: "AddMachineIntent" });
  expect(shortcutIntent(shortcuts, key("3", { ctrl: true }), false)).toEqual({ kind: "ShowPanelTabIntent", tab: "tree" });
  expect(shortcutIntent(shortcuts, key(",", { meta: true }), true)).toEqual({ kind: "OpenSettingsIntent" });
  expect(shortcutIntent(shortcuts, key("Escape"), true)).toEqual({ kind: "AbortRunIntent" });
  expect(shortcutIntent(shortcuts, key("Escape", { meta: true }), true)).toBeNull();
});
