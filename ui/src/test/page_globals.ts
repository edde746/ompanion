// What app modules expect of a page and bun lacks: localStorage (the settings and platform snapshots) and the parts of
// `location` and `document` that app/platform.ts reads as it loads. A test file imports this module first, before any
// module that reaches app/platform.ts (MachineConnector, KnownHostsStore) or constructs a SettingsProvider.
const items = new Map<string, string>();

define("localStorage", {
  getItem: (key: string) => items.get(key) ?? null,
  setItem: (key: string, value: string) => void items.set(key, value),
  removeItem: (key: string) => void items.delete(key),
  clear: () => items.clear(),
});
define("location", { search: "" });
define("document", { documentElement: { dataset: {}, style: { setProperty: () => undefined } } });

function define(name: string, value: object): void {
  if (Reflect.get(globalThis, name) === undefined) {
    Object.defineProperty(globalThis, name, { value, configurable: true, writable: true });
  }
}
