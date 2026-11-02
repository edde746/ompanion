// Port of test/config/settings_test.dart.
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { asJsonObject, FormatException } from "../../core/rpc/json_fields";
import type { ConfigLayer } from "./config_yaml";
import {
  type KnownValue,
  provenanceFromWire,
  type SettingSchema,
  settingsSchemaFromJson,
  settingsSnapshotFromJson,
  settingsSnapshotMerge,
  type SettingValue,
} from "./settings_schema";
import {
  advancedTab,
  displayFor,
  editorFor,
  JsonValueException,
  type JsonValueProblem,
  parseJsonValue,
  parseNumber,
  type SettingEditor,
  settingsSections,
} from "./settings_view";

// Real `settings.schema` / `settings.get` replies of omp 18.3.1 with the companion (a subset of the 512 settings),
// captured from a `--no-session` rpc-ui process in an isolated home.
function fixture(name: string): unknown {
  return JSON.parse(readFileSync(join(import.meta.dir, "fixtures", name), "utf8"));
}

const schema = settingsSchemaFromJson(asJsonObject(fixture("settings-schema.json"), "schema"));
const snapshot = settingsSnapshotFromJson(asJsonObject(fixture("settings-get.json"), "settings"));

function setting(path: string): SettingSchema {
  const found = schema.byPath.get(path);
  if (found === undefined) throw new Error(`no setting ${path}`);
  return found;
}

function value(path: string): SettingValue | undefined {
  return snapshot.values.get(path);
}

function editor(path: string): SettingEditor {
  const current = value(path);
  return editorFor(setting(path), current?.kind === "KnownValue" ? current.value : undefined);
}

function editorOf<K extends SettingEditor["kind"]>(path: string, kind: K): Extract<SettingEditor, { kind: K }> {
  const found = editor(path);
  if (found.kind !== kind) throw new Error(`${path}: ${found.kind}, not ${kind}`);
  return found as Extract<SettingEditor, { kind: K }>;
}

const empty: ConfigLayer = { root: {} };

describe("editorFor", () => {
  test("booleans switch", () => {
    expect(editor("autoResume").kind).toBe("SwitchEditor");
  });

  test("enums offer the panel options with their labels, else the bare enum values", () => {
    const labelled = editorOf("modelRoleStorage", "ChoiceEditor");
    expect(labelled.options.map((option) => [option.value, option.label])).toEqual([
      ["global", "Global"],
      ["project", "Per-project"],
    ]);
    const bare = editorOf("hindsight.recallBudget", "ChoiceEditor");
    expect(bare.options.map((option) => option.label)).toEqual(["low", "mid", "high"]);
  });

  test("numbers take any value and keep omp presets as suggestions", () => {
    const number = editorOf("loop.conditionTimeoutMs", "NumberEditor");
    expect(number.presets[0]?.value).toBe("0");
    expect(number.presets[0]?.label).toBe("Unlimited");
    expect(editor("edit.fuzzyThreshold").kind).toBe("NumberEditor");
  });

  test("strings with installed choices pick one; runtime-filled choices are free text", () => {
    expect(editorOf("theme.dark", "ChoiceEditor").options.map((option) => option.value)).toContain("titanium");
    expect(editor("composer.shape").kind).toBe("TextEditor");
    expect(editor("mnemopi.embeddingModel").kind).toBe("TextEditor");
  });

  test("credentials are write-only, whatever their type", () => {
    expect(editor("auth.broker.token").kind).toBe("SecretEditor");
    expect(editor("mnemopi.embeddingApiKey").kind).toBe("SecretEditor");
    expect(editorOf("images.urls.credentials", "SecretEditor").type).toBe("record");
  });

  test("closed-vocabulary arrays choose from it; ordered ones keep the order", () => {
    const segments = editorOf("statusLine.leftSegments", "MultiChoiceEditor");
    expect(segments.ordered).toBe(true);
    expect(segments.options.map((option) => option.value)).toEqual(expect.arrayContaining(["model", "git", "cost"]));
    const methods = editorOf("compaction.methodOrder", "MultiChoiceEditor");
    expect(methods.ordered).toBe(true);
    expect(methods.options.map((option) => option.value)).toEqual(expect.arrayContaining(["remote", "soft"]));
  });

  test("arrays of objects, path-scoped arrays and records edit as JSON; string arrays as a list", () => {
    expect(editor("bashInterceptor.patterns").kind).toBe("JsonEditor");
    expect(editor("enabledModels").kind).toBe("JsonEditor");
    expect(editor("tools.approval").kind).toBe("JsonEditor");
    expect(editor("modelRoles").kind).toBe("JsonEditor");
    expect(editor("ttsr.disabledRules").kind).toBe("StringListEditor");
    // A hand-edited file may put an object into a string list.
    expect(editorFor(setting("ttsr.disabledRules"), [{ name: "x" }]).kind).toBe("JsonEditor");
  });
});

describe("SettingValue", () => {
  test("decodes provenance and redacted credentials", () => {
    expect(provenanceFromWire("default")).toBe("default");
    expect(value("advisor.enabled")).toMatchObject({ kind: "KnownValue", provenance: "runtime" });
    expect(value("startup.checkUpdate")).toMatchObject({ kind: "KnownValue", provenance: "global" });
    expect(value("images.urls.credentials")?.kind).toBe("RedactedValue");
    expect(() => provenanceFromWire("file")).toThrow(FormatException);
  });

  test("settings.changed replaces only the changed entries", () => {
    const changed = settingsSnapshotFromJson({
      settings: [{ path: "autoResume", value: true, provenance: "global" }],
      conditions: { advisorEnabled: true },
    });
    const merged = settingsSnapshotMerge(snapshot, changed);
    expect((merged.values.get("autoResume") as KnownValue).value).toBe(true);
    expect((merged.values.get("theme.dark") as KnownValue).value).toBe("titanium");
    expect(merged.conditions.advisorEnabled).toBe(true);
  });
});

describe("displayFor", () => {
  test("an override above the global file shows the file layer and names the override", () => {
    // RPC mode forces advisor off in every rpc process; the global file holds the user's own choice.
    const global: ConfigLayer = { root: { advisor: { enabled: true } } };
    const display = displayFor(setting("advisor.enabled"), value("advisor.enabled"), "global", {
      global,
      project: undefined,
    });
    expect(display.value).toBe(true);
    expect(display.setHere).toBe(true);
    expect(display.overriddenBy).toBe("runtime");

    const unset = displayFor(setting("advisor.enabled"), value("advisor.enabled"), "global", {
      global: empty,
      project: undefined,
    });
    expect(unset.value).toBe(setting("advisor.enabled").defaultValue);
    expect(unset.setHere).toBe(false);
  });

  test("the global value is the effective one while nothing outranks it", () => {
    const global: ConfigLayer = { root: { startup: { checkUpdate: false } } };
    const display = displayFor(setting("startup.checkUpdate"), value("startup.checkUpdate"), "global", {
      global,
      project: undefined,
    });
    expect(display.value).toBe(false);
    expect(display.setHere).toBe(true);
    expect(display.overriddenBy).toBeUndefined();
  });

  test("project scope shows the project file, else the inherited global value", () => {
    const global: ConfigLayer = { root: { theme: { dark: "basalt" } } };
    const project: ConfigLayer = { root: { theme: { dark: "birch" } } };
    const effective: KnownValue = { kind: "KnownValue", path: "theme.dark", provenance: "global", value: "basalt" };
    const own = displayFor(setting("theme.dark"), effective, "project", { global, project });
    expect(own.value).toBe("birch");
    expect(own.setHere).toBe(true);
    const inherited = displayFor(setting("theme.dark"), effective, "project", { global, project: empty });
    expect(inherited.value).toBe("basalt");
    expect(inherited.setHere).toBe(false);
  });

  test("a project value outranks global in global scope", () => {
    const effective: KnownValue = { kind: "KnownValue", path: "theme.dark", provenance: "project", value: "birch" };
    const display = displayFor(setting("theme.dark"), effective, "global", { global: empty, project: undefined });
    expect(display.overriddenBy).toBe("project");
    expect(display.value).toBe("titanium");
  });

  test("an environment variable overrides every layer", () => {
    const effective: KnownValue = {
      kind: "KnownValue",
      path: "mnemopi.embeddingModel",
      provenance: "env",
      value: undefined,
    };
    const display = displayFor(setting("mnemopi.embeddingModel"), effective, "project", {
      global: empty,
      project: empty,
    });
    expect(display.overriddenBy).toBe("env");
  });

  test("without a readable global file, the effective provenance decides", () => {
    const display = displayFor(setting("startup.checkUpdate"), value("startup.checkUpdate"), "global", {
      global: undefined,
      project: undefined,
    });
    expect(display.value).toBe(false);
    expect(display.setHere).toBe(true);
  });

  test("secrets never carry a value; a configured one is reported as such", () => {
    const configured = displayFor(
      setting("auth.broker.token"),
      { kind: "RedactedValue", path: "auth.broker.token", provenance: "global" },
      "global",
      { global: { root: { auth: { broker: { token: "secret-in-file" } } } }, project: undefined },
    );
    expect(configured.value).toBeUndefined();
    expect(configured.configured).toBe(true);
    expect(configured.setHere).toBe(true);
    // omp's own default is not a configured credential.
    const defaulted = displayFor(setting("images.urls.credentials"), value("images.urls.credentials"), "global", {
      global: empty,
      project: undefined,
    });
    expect(defaulted.configured).toBe(false);
  });
});

describe("settingsSections", () => {
  test("a tab lists its groups in first-appearance order", () => {
    const sections = settingsSections(schema, { tab: "model", conditions: snapshot.conditions });
    expect(sections.every((section) => section.tab === "model")).toBe(true);
    const groups = sections.map((section) => section.group);
    expect(new Set(groups).size).toBe(groups.length);
    expect(sections.flatMap((section) => section.settings.map((s) => s.path))).toEqual(
      expect.arrayContaining(["modelRoleStorage", "externalThinking"]),
    );
  });

  test("rows whose condition is false are hidden", () => {
    const hidden = settingsSections(schema, { tab: "memory", conditions: { mnemopiActive: false } });
    expect(hidden.flatMap((section) => section.settings.map((s) => s.path))).not.toContain("mnemopi.embeddingModel");
    const shown = settingsSections(schema, { tab: "memory", conditions: { mnemopiActive: true } });
    expect(shown.flatMap((section) => section.settings.map((s) => s.path))).toContain("mnemopi.embeddingModel");
  });

  test("config-file-only settings sit in the advanced tab, grouped by their first key", () => {
    const advanced = settingsSections(schema, { tab: advancedTab });
    const paths = advanced.flatMap((section) => section.settings.map((s) => s.path));
    expect(paths).toEqual(expect.arrayContaining(["modelRoles", "enabledModels", "retry.enabled"]));
    expect(advanced.find((section) => section.settings.some((s) => s.path === "retry.enabled"))?.group).toBe("retry");
  });

  test("a search spans every tab and matches all words", () => {
    const results = settingsSections(schema, { tab: "appearance", query: "loop guard", conditions: snapshot.conditions });
    const paths = results.flatMap((section) => section.settings.map((s) => s.path));
    expect(paths).toContain("model.loopGuard.enabled");
    expect(paths).not.toContain("theme.dark");
    expect(settingsSections(schema, { tab: "appearance", query: "no-such-thing" })).toEqual([]);
  });
});

describe("value parsing", () => {
  test("numbers keep integers integral", () => {
    expect(parseNumber("30000")).toBe(30000);
    expect(Number.isInteger(parseNumber("30000"))).toBe(true);
    expect(parseNumber(" 0.9 ")).toBe(0.9);
    expect(parseNumber("abc")).toBeUndefined();
    expect(parseNumber("")).toBeUndefined();
    expect(parseNumber("0x10")).toBeUndefined();
  });

  test("NaN and the infinities are not numbers", () => {
    for (const text of ["NaN", "Infinity", "-Infinity", "1e999"]) expect(parseNumber(text)).toBeUndefined();
  });

  test("JSON must match the setting type", () => {
    const refused = (text: string, type: "record" | "array"): JsonValueProblem | undefined => {
      try {
        parseJsonValue(text, type);
      } catch (error) {
        if (error instanceof JsonValueException) return error.problem;
        throw error;
      }
      return undefined;
    };
    expect(parseJsonValue('{"bash": "allow"}', "record")).toEqual({ bash: "allow" });
    expect(refused("[1]", "record")).toBe("notObject");
    expect(refused("{}", "array")).toBe("notArray");
    expect(refused("{", "record")).toBe("notJson");
  });
});
