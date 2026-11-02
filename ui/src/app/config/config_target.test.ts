// Port of test/config/config_target_test.dart.
import { expect, test } from "bun:test";
import { FakeSessions, fakeRuntime, MemoryFiles, testMachine } from "../../test/config_fakes";
import { ConfigTarget } from "./config_target";

// omp 18.3.1 reads the profile's config.yml, else config.yaml (MAIN_CONFIG_FILENAMES), but a project's .omp/config.yml
// only (settings.ts #readProjectSettings, the native settings provider in builtin.ts).
test("the settings files are the ones omp reads", async () => {
  const files = new MemoryFiles();
  files.texts.set("/home/u/.omp/agent/config.yaml", "theme: {}\n");
  files.texts.set("/work/p/.omp/config.yaml", "theme: {}\n");
  const target = new ConfigTarget(testMachine, new FakeSessions(fakeRuntime(files)));

  expect(await target.globalConfigPath()).toBe("/home/u/.omp/agent/config.yaml");
  expect(target.projectConfigPath("/work/p")).toBe("/work/p/.omp/config.yml");
  files.texts.set("/home/u/.omp/agent/config.yml", "");
  expect(await target.globalConfigPath()).toBe("/home/u/.omp/agent/config.yml");
});

test("a written file gets its parent directory and reads back; a missing one reads as undefined", async () => {
  const files = new MemoryFiles();
  const target = new ConfigTarget(testMachine, new FakeSessions(fakeRuntime(files)));
  expect(await target.readText("/work/p/.omp/config.yml")).toBeUndefined();
  await target.writeText("/work/p/.omp/config.yml", "a: 1\n");
  expect(await target.readText("/work/p/.omp/config.yml")).toBe("a: 1\n");
});
