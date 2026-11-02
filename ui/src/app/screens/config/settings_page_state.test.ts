// Port of test/screens/config/settings_page_test.dart: the page's contracts, on its state without the markup.
import { afterEach, expect, test } from "bun:test";
import { createRoot, flush } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import { deferred } from "../../../deferred";
import { FakeSession, FakeSessions, fakeRuntime, MemoryFiles, testMachine } from "../../../test/config_fakes";
import { ConfigTarget } from "../../config/config_target";
import { configLayerLookup, configLayerParse } from "../../config/config_yaml";
import type { SettingSchema } from "../../config/settings_schema";
import { SettingsPageState } from "./settings_page_state";

function switchSetting(path: string, label: string) {
  return {
    path,
    type: "boolean",
    default: false,
    isCredential: false,
    ui: { tab: "general", label, description: "" },
  };
}

const values = {
  settings: ["alpha.enabled", "beta.enabled"].map((path) => ({ path, provenance: "default", value: false })),
  conditions: {},
};

function replies(verb: string): unknown {
  switch (verb) {
    case "settings.schema":
      return {
        tabs: ["general"],
        settings: [switchSetting("alpha.enabled", "Alpha"), switchSetting("beta.enabled", "Beta")],
        conditions: {},
      };
    case "settings.get":
      return values;
    default:
      throw new Error(`unexpected ${verb}`);
  }
}

let dispose: (() => void) | undefined;

afterEach(() => dispose?.());

async function page(project?: LiveSession) {
  const files = new MemoryFiles();
  const control = await new FakeSession({ reply: replies }).attach();
  const sessions = new FakeSessions(fakeRuntime(files));
  sessions.onControl = async () => control;
  sessions.activeSession = project;
  const state = createRoot((done) => {
    dispose = done;
    return new SettingsPageState(new ConfigTarget(testMachine, sessions));
  });
  await state.load();
  flush();
  return { files, control, sessions, state };
}

/** Flushes and yields until [condition] holds. */
async function until(condition: () => boolean): Promise<void> {
  for (let tries = 0; tries < 100; tries++) {
    flush();
    if (condition()) return;
    await Bun.sleep(0);
  }
  throw new Error("timed out");
}

function settingOf(state: SettingsPageState, path: string): SettingSchema {
  const setting = state.schema()?.byPath.get(path);
  if (setting === undefined) throw new Error(`no setting ${path}`);
  return setting;
}

test("project edits made one after another all reach .omp/config.yml", async () => {
  const project = await new FakeSession({ cwd: "/work/p", runId: "run", reply: replies }).attach();
  const { files, state } = await page(project);
  state.changeScope("project");
  await until(() => state.projectPath() !== undefined && !state.loading());

  // The first edit's write is still on its way when the second edit starts.
  const gate = deferred<void>();
  files.writeGate = gate;
  const first = state.write(settingOf(state, "alpha.enabled"), true);
  const second = state.write(settingOf(state, "beta.enabled"), true);
  await until(() => files.writesStarted === 1);
  gate.resolve();
  await Promise.all([first, second]);

  const written = configLayerParse(files.texts.get("/work/p/.omp/config.yml") ?? "");
  expect(configLayerLookup(written, ["alpha", "enabled"])?.value).toBe(true);
  expect(configLayerLookup(written, ["beta", "enabled"])?.value).toBe(true);
});

test("a reload that ends after the page closed leaves no listener behind", async () => {
  const { control, sessions, state } = await page();
  const before = state.effective();
  expect(before).toBeDefined();
  const reload = deferred<LiveSession>();
  sessions.onControl = () => reload.promise;
  const pending = state.load();
  state.dispose();

  reload.resolve(control);
  await pending;
  control.omp.emit({
    kind: "event",
    event: "settings.changed",
    data: { settings: [{ path: "alpha.enabled", provenance: "global", value: true }], conditions: {} },
  });
  flush();
  expect(state.effective()).toBe(before);
});

test("settings.changed of the page's source updates the effective values", async () => {
  const { control, state } = await page();
  control.omp.emit({
    kind: "event",
    event: "settings.changed",
    data: { settings: [{ path: "alpha.enabled", provenance: "global", value: true }], conditions: {} },
  });
  await until(() => state.effective()?.values.get("alpha.enabled")?.provenance === "global");
  state.dispose();
});
