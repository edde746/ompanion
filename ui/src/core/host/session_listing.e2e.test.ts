import { afterEach, beforeEach, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { localLink, useCore } from "../../test/core";
import { expectFixtureSessions, macArm, writeSessionFixtures } from "../../test/host_fixtures";
import { listSessions } from "./session_listing";

useCore();

let root: string;

beforeEach(() => {
  root = mkdtempSync(join(tmpdir(), "listing-"));
});

afterEach(() => {
  rmSync(root, { recursive: true, force: true });
});

test("lists every profile and directory from the first 16 KiB of each file, newest first", async () => {
  const home = `${root}/home`;
  await writeSessionFixtures(home, root);
  const link = localLink({ HOME: home, PI_CODING_AGENT_DIR: `${root}/custom agent`, PI_CONFIG_DIR: "" });
  try {
    const listed = await listSessions(link, macArm, { sessionDirs: [`${root}/session dir`] });
    expectFixtureSessions(listed, `${home}/.omp/agent/sessions`);
  } finally {
    await link.close();
  }
});
