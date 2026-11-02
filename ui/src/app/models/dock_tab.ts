/** Tabs of the right dock, in display order. */
export const dockTabs = ["agents", "todos", "tree", "files", "terminal"] as const;

export type DockTab = (typeof dockTabs)[number];
