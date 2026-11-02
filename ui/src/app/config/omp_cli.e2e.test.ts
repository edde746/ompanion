// Port of test/config/omp_cli_test.dart, on this computer through the core. The one-shot `omp` calls behind the
// settings, roles, skills and plugin pages: the process must see the login shell's PATH in front of the link's own,
// and nothing must change when the probe read none.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { hostProbe, type HostProbe } from "../../core/host/probe";
import type { HostLink } from "../../core/transport/host_link";
import { localLink, useCore } from "../../test/core";
import { OmpCliException, runOmp } from "./omp_cli";

useCore();

let home: string;
let link: HostLink;

beforeEach(async () => {
  home = await mkdtemp(join(tmpdir(), "omp-cli-"));
  link = localLink({ HOME: home, PATH: "/usr/bin:/bin" });
});

afterEach(async () => {
  await link.close();
  await rm(home, { recursive: true });
});

/** A probe of this computer whose "omp" is `/bin/sh`, so the arguments can ask the process for its PATH. */
function probe(loginPath?: string): HostProbe {
  return hostProbe({
    commandShell: "posix",
    os: process.platform === "darwin" ? "macos" : "linux",
    kernel: process.platform === "darwin" ? "Darwin" : "Linux",
    arch: "arm64",
    home,
    agentDir: `${home}/.omp/agent`,
    ompPath: "/bin/sh",
    loginPath,
  });
}

test("the login shell PATH is in front, verbatim, the link PATH behind it", async () => {
  const login = "/opt/homebrew/bin:/Users/me/it's here/$(exit 7)/`exit 8`/\\x";
  const result = await runOmp(link, probe(login), ["-c", 'printf %s "$PATH"']);
  expect(result.stdout).toBe(`${login}:/usr/bin:/bin`);
});

test("without a login PATH the process keeps the link PATH", async () => {
  const result = await runOmp(link, probe(), ["-c", 'printf %s "$PATH"']);
  expect(result.stdout).toBe("/usr/bin:/bin");
});

test("a non-zero exit is an OmpCliException with what omp printed", async () => {
  const error = await runOmp(link, probe(), ["-c", "echo nope >&2; exit 3"]).then(
    () => undefined,
    (failure: unknown) => failure,
  );
  expect(error).toBeInstanceOf(OmpCliException);
  expect((error as OmpCliException).ompMessage).toBe("nope");
});
