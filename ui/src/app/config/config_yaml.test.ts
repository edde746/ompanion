// Port of test/config/config_yaml_test.dart.
import { describe, expect, test } from "bun:test";
import { FormatException } from "../../core/rpc/json_fields";
import { configLayerLookup, configLayerParse, removeConfigValue, setConfigValue } from "./config_yaml";

// What harness/omp-home.sh writes, with a comment a user added: the edits must keep both.
const base = `# project settings
startup:
  checkUpdate: false
marketplace:
  autoUpdate: "off" # never
lsp:
  enabled: false
`;

function valueAt(source: string, path: string[]): unknown {
  return configLayerLookup(configLayerParse(source), path)?.value;
}

function failure(edit: () => unknown): Error {
  try {
    edit();
  } catch (error) {
    if (error instanceof Error) return error;
    throw error;
  }
  throw new Error("expected the edit to throw");
}

describe("setConfigValue", () => {
  test("an empty file gets the nested map", () => {
    const written = setConfigValue("", ["theme", "dark"], "basalt");
    expect(valueAt(written, ["theme", "dark"])).toBe("basalt");
  });

  test("updates a nested key and keeps comments and the other keys", () => {
    const written = setConfigValue(base, ["startup", "checkUpdate"], true);
    expect(valueAt(written, ["startup", "checkUpdate"])).toBe(true);
    expect(valueAt(written, ["marketplace", "autoUpdate"])).toBe("off");
    expect(valueAt(written, ["lsp", "enabled"])).toBe(false);
    expect(written).toContain("# project settings");
    expect(written).toContain("# never");
  });

  test("a comment after a changed value on its line stays", () => {
    const written = setConfigValue(base, ["marketplace", "autoUpdate"], "notify");
    expect(valueAt(written, ["marketplace", "autoUpdate"])).toBe("notify");
    expect(written).toContain("# never");
  });

  test("adds keys under an existing parent and creates missing parents", () => {
    const sibling = setConfigValue(base, ["startup", "quiet"], true);
    expect(valueAt(sibling, ["startup", "checkUpdate"])).toBe(false);
    expect(valueAt(sibling, ["startup", "quiet"])).toBe(true);
    const deep = setConfigValue(base, ["providers", "openai-codex", "codeModeDirectTools"], ["eval", "ask"]);
    expect(valueAt(deep, ["providers", "openai-codex", "codeModeDirectTools"])).toEqual(["eval", "ask"]);
  });

  test("collections and numbers round-trip", () => {
    const written = setConfigValue(base, ["tools", "approval"], { bash: "prompt", read: "allow" });
    expect(valueAt(written, ["tools", "approval"])).toEqual({ bash: "prompt", read: "allow" });
    const number = setConfigValue(written, ["loop", "conditionTimeoutMs"], 30000);
    expect(valueAt(number, ["loop", "conditionTimeoutMs"])).toBe(30000);
    expect(number).toContain("conditionTimeoutMs: 30000\n");
  });

  test("words YAML 1.1 reads as booleans stay strings", () => {
    const written = setConfigValue("", ["power", "sleepPrevention"], "off");
    expect(written).toContain('"off"');
    expect(valueAt(written, ["power", "sleepPrevention"])).toBe("off");
  });

  test("a parent holding a scalar is refused", () => {
    expect(() => setConfigValue("theme: dark\n", ["theme", "dark"], "x")).toThrow(FormatException);
    expect(() => setConfigValue("- a\n- b\n", ["theme"], "x")).toThrow(FormatException);
  });

  test("a file holding only comments keeps them", () => {
    for (const source of ["# keep me\n# and me\n", "---\n# keep me\n...\n", "# keep me", "# keep me\n~\n"]) {
      const written = setConfigValue(source, ["a", "b"], true);
      expect(valueAt(written, ["a", "b"])).toBe(true);
      expect(written).toContain("# keep me");
    }
    expect(setConfigValue("# keep me\n# and me\n", ["a", "b"], true)).toContain("# and me");
  });

  test("a file with CRLF line ends keeps them", () => {
    const written = setConfigValue("# keep me\r\nstartup:\r\n  checkUpdate: false\r\n", ["startup", "quiet"], true);
    expect(written).toContain("# keep me\r\n");
    expect(written.replaceAll("\r\n", "")).not.toContain("\n");
  });
});

describe("removeConfigValue", () => {
  test("removes the key and parents it leaves empty, keeping the rest", () => {
    const removed = removeConfigValue(base, ["lsp", "enabled"]);
    const layer = configLayerParse(removed);
    expect(configLayerLookup(layer, ["lsp"])).toBeUndefined();
    expect(configLayerLookup(layer, ["startup", "checkUpdate"])?.value).toBe(false);
    expect(removed).toContain("# project settings");
  });

  test("keeps a parent that still has keys", () => {
    const twoKeys = setConfigValue(base, ["startup", "quiet"], true);
    const removed = removeConfigValue(twoKeys, ["startup", "quiet"]);
    expect(valueAt(removed, ["startup", "checkUpdate"])).toBe(false);
    expect(configLayerLookup(configLayerParse(removed), ["startup", "quiet"])).toBeUndefined();
  });

  test("a missing key leaves the file untouched", () => {
    expect(removeConfigValue(base, ["theme", "dark"])).toBe(base);
    expect(removeConfigValue(base, ["startup", "checkUpdate", "deeper"])).toBe(base);
  });
});

test("edit errors name the setting or the position, never the file text", () => {
  const secret = "sk-SECRET-123";
  const edits = [
    () => setConfigValue(`apiKey: ${secret}\nx: 1\n`, ["x"], Number.NaN),
    () => setConfigValue(`apiKey: ${secret}: oops\n`, ["x"], 1),
    () => setConfigValue(`base: &b\n  apiKey: ${secret}\nother: *b\n`, ["other", "x"], 1),
    () => removeConfigValue(`base: &b\n  apiKey: ${secret}\nother: *b\n`, ["other", "apiKey"]),
  ];
  for (const edit of edits) {
    const error = failure(edit);
    expect(error).toBeInstanceOf(FormatException);
    expect(String(error)).not.toContain(secret);
  }
});

describe("ConfigLayer", () => {
  test("an empty or comment-only file is an empty layer; a present null is a hit", () => {
    expect(configLayerParse("").root).toEqual({});
    expect(configLayerParse("# nothing\n").root).toEqual({});
    const hit = configLayerLookup(configLayerParse("theme:\n  dark:\n"), ["theme", "dark"]);
    expect(hit).toBeDefined();
    expect(hit?.value).toBeUndefined();
  });

  test("a broken file reports its position without quoting it", () => {
    const leaky = 'auth:\n  broker:\n    token: "sk-live-123\n  other: [\n';
    const error = failure(() => configLayerParse(leaky));
    expect(error).toBeInstanceOf(FormatException);
    expect(error.message).toContain("line");
    expect(error.message).not.toContain("sk-live-123");
    expect(() => configLayerParse("- a\n")).toThrow(FormatException);
  });
});
