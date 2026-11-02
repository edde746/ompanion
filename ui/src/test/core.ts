// The real Go core for e2e tests: a test file calls useCore() at its top level, and src/bridge.ts talks to a dev
// bridge (core/cmd/devbridge) started for that file. The core's HOME, data and cache directories are fresh
// temporary ones, so nothing a test does reaches the account's own.
import { afterAll, beforeAll } from "bun:test";
import type { Subprocess } from "bun";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { disconnect } from "../bridge";
import { BridgeLink } from "../core/transport/bridge_link";

const repo = path.resolve(import.meta.dir, "../../..");
const binary = path.join(repo, "build", process.platform === "win32" ? "devbridge.exe" : "devbridge");

type DevBridge = Subprocess<"ignore", "ignore", "pipe">;

let built: Promise<void> | undefined;
let running: { child: DevBridge; root: string } | undefined;
let users = 0;

/** Starts the core before the file's tests and stops it after them. */
export function useCore(): void {
  beforeAll(startCore, 120_000);
  afterAll(stopCore);
}

/** This computer through the core; [environment] is added to every process's, e.g. an isolated `HOME`. */
export function localLink(environment?: Record<string, string>): BridgeLink {
  return new BridgeLink("local", { environment });
}

function build(): Promise<void> {
  built ??= (async () => {
    const version = (await Bun.file(path.join(repo, "VERSION")).text()).trim();
    const ldflags = `-X ompanion.app/core.Version=${version}`;
    const go = Bun.spawn(["go", "build", "-ldflags", ldflags, "-o", binary, "./cmd/devbridge"], {
      cwd: path.join(repo, "core"),
      stdout: "ignore",
      stderr: "pipe",
    });
    const [code, stderr] = await Promise.all([go.exited, new Response(go.stderr).text()]);
    if (code !== 0) throw new Error(`go build ./cmd/devbridge exited ${code}: ${stderr.trim()}`);
  })();
  return built;
}

async function startCore(): Promise<void> {
  if (users++ > 0) return;
  await build();
  const root = await fs.mkdtemp(path.join(os.tmpdir(), "ompcore-test-"));
  const dirs = { HOME: `${root}/home`, OMPCORE_DATA_DIR: `${root}/data`, OMPCORE_CACHE_DIR: `${root}/cache` };
  for (const dir of Object.values(dirs)) await fs.mkdir(dir);
  const child: DevBridge = Bun.spawn([binary, "-listen", "127.0.0.1:0"], {
    env: { ...process.env, ...dirs },
    stdin: "ignore",
    stdout: "ignore",
    stderr: "pipe",
  });
  running = { child, root };
  const url = await bridgeUrl(child);
  // Requests made after the previous core stopped (by a test that left a stream open) left the bridge broken or
  // bound to nothing; start from a clean one.
  await disconnect();
  process.env.OMPCORE_DEVBRIDGE = url;
}

/**
 * Reads the dev bridge's stderr until it names its address, then keeps passing it on to this process's stderr,
 * where the core's own log lines help when a test fails.
 */
async function bridgeUrl(child: DevBridge): Promise<string> {
  const reader = child.stderr.getReader();
  const decoder = new TextDecoder();
  let seen = "";
  for (;;) {
    const { value, done } = await reader.read();
    if (done) throw new Error(`devbridge exited before it listened: ${seen.trim()}`);
    seen += decoder.decode(value, { stream: true });
    const url = /ws:\/\/\S+\/bridge/.exec(seen)?.[0];
    if (url === undefined) continue;
    process.stderr.write(seen);
    void passOn(reader);
    return url;
  }
}

async function passOn(reader: ReadableStreamDefaultReader<Uint8Array>): Promise<void> {
  for (;;) {
    const { value, done } = await reader.read();
    if (done) return;
    process.stderr.write(value);
  }
}

async function stopCore(): Promise<void> {
  if (--users > 0 || !running) return;
  const { child, root } = running;
  running = undefined;
  // Unset first: a test whose stream ends here may send follow-up requests, which must not reconnect to this core.
  delete process.env.OMPCORE_DEVBRIDGE;
  await disconnect();
  child.kill();
  await child.exited;
  await fs.rm(root, { recursive: true, force: true });
}

// A test run that ends abnormally must not leave a core behind.
process.on("exit", () => running?.child.kill());
