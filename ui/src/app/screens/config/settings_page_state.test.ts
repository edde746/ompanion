// Port of test/screens/config/settings_page_test.dart: the page's contracts, on its state without the markup.
import { afterEach, expect, test } from "bun:test";
import { createRoot, flush } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import { type Deferred, deferred } from "../../../deferred";
import { FakeSession, FakeSessions, fakeRuntime, MemoryFiles, testMachine } from "../../../test/config_fakes";
import { ConfigTarget } from "../../config/config_target";
import { type ConfigLayer, configLayerLookup, configLayerParse } from "../../config/config_yaml";
import type { SettingSchema } from "../../config/settings_schema";
import { SettingsPageState } from "./settings_page_state";

/** Files whose next read, once it has the bytes, waits for [held]: a reload stopped partway. */
class HeldFiles extends MemoryFiles {
  held: Deferred<void> | undefined;

  override async read(path: string): Promise<Uint8Array> {
    const bytes = await super.read(path);
    const held = this.held;
    this.held = undefined;
    await held?.promise;
    return bytes;
  }
}

const globalPath = "/home/u/.omp/agent/config.yml";

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

/** The project session's `settings.get`: every value comes from the project file. */
function projectReplies(verb: string): unknown {
  if (verb !== "settings.get") return replies(verb);
  return { settings: values.settings.map((value) => ({ ...value, provenance: "project" })), conditions: {} };
}

let dispose: (() => void) | undefined;

afterEach(() => dispose?.());

async function page(project?: LiveSession) {
  const files = new HeldFiles();
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

test("a reload of the scope left behind changes neither the values nor the spinner of the new scope", async () => {
  const project = await new FakeSession({ cwd: "/work/p", runId: "run", reply: projectReplies }).attach();
  const { files, state } = await page(project);
  files.texts.set(globalPath, "alpha:\n  enabled: false\n");

  const refresh = deferred<void>();
  files.held = refresh;
  const refreshed = state.load();
  await until(() => files.held === undefined);
  const scoped = deferred<void>();
  files.held = scoped;
  state.changeScope("project");
  await until(() => files.held === undefined);

  // The global refresh ends first, while the project load still runs.
  refresh.resolve();
  await refreshed;
  flush();
  expect(state.loading()).toBe(true);
  expect(state.effective()).toBeUndefined();

  scoped.resolve();
  await until(() => !state.loading());
  expect(state.scope()).toBe("project");
  expect(state.effective()?.values.get("alpha.enabled")?.provenance).toBe("project");
});

test("a file reload that ends after a newer one leaves the newer text", async () => {
  const { files, state } = await page();
  files.texts.set(globalPath, "alpha:\n  enabled: false\n");
  const held = deferred<void>();
  files.held = held;
  const older = state.load();
  await until(() => files.held === undefined);

  files.texts.set(globalPath, "alpha:\n  enabled: true\n");
  await state.load();
  held.resolve();
  await older;
  flush();
  const global: ConfigLayer = state.global() ?? { root: {} };
  expect(configLayerLookup(global, ["alpha", "enabled"])?.value).toBe(true);
});
