// Port of packages/omp_core/test/host/install_test.dart, run on this computer through the core.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { existsSync, readdirSync } from "node:fs";
import { chmod, mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import type { Server } from "bun";
import { call } from "../../bridge";
import { localLink, useCore } from "../../test/core";
import { macArm } from "../../test/host_fixtures";
import { ompBinary, testedOmpVersion, thisComputer } from "../../test/omp";
import { asJsonObject, string } from "../rpc/json_fields";
import { BridgeLink, type CachedFile } from "../transport/bridge_link";
import { type ExecOptions, HostLinkException, type HostFiles, type HostProcess } from "../transport/host_link";
import { fetchOmpAsset, posixInstallCommand, updateOmp, uploadOmp } from "./install";
import { hostProbe, hostProbeReleaseAsset, type HostProbe } from "./probe";
import { runPosixScript } from "./scripts";

useCore();

let temp: string;
let link: BridgeLink;

beforeEach(async () => {
  temp = await mkdtemp(join(tmpdir(), "install-"));
  link = localLink({ HOME: temp });
});

afterEach(async () => {
  await link.close();
  await rm(temp, { recursive: true });
});

/** Serves this computer's release asset of the tested omp under `/real/`, and bytes that are not omp under `/fake/`. */
let releases: Server<undefined>;

beforeAll(() => {
  const asset = hostProbeReleaseAsset(thisComputer)!;
  releases = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: (request) => {
      const path = new URL(request.url).pathname;
      if (path === `/real/${asset}`) return new Response(Bun.file(ompBinary));
      if (path === `/fake/${asset}`) return new Response("not omp");
      return new Response("not found", { status: 404 });
    },
  });
});

afterAll(async () => {
  await releases.stop(true);
});

const fetchAsset = (kind: "real" | "fake") =>
  fetchOmpAsset(thisComputer, testedOmpVersion, { assetBase: `http://127.0.0.1:${releases.port}/${kind}/` });

async function isCached(file: CachedFile): Promise<boolean> {
  return existsSync(`${string(asJsonObject(await call("core.paths"), "core.paths"), "cache")}/${file.name}`);
}

test("an asset whose digest is not the release's is refused before anything is uploaded, and leaves the cache", async () => {
  const dir = `${temp}/bin`;
  const asset = await fetchAsset("fake");
  expect(await isCached(asset)).toBe(true);
  const install = uploadOmp(link, thisComputer, testedOmpVersion, { asset, installDir: dir });
  await expect(install).rejects.toBeInstanceOf(HostLinkException);
  await expect(install).rejects.toThrow("SHA-256 mismatch");
  expect(existsSync(dir)).toBe(false);
  expect(existsSync(`${temp}/.ompanion/install.lock`)).toBe(false);
  expect(await isCached(asset)).toBe(false);
});

test("the core fetches the release asset and uploads it, and the machine checks, runs and places it", async () => {
  const dir = `${temp}/bin`;
  const asset = await fetchAsset("real");
  expect(asset.size).toBe(Bun.file(ompBinary).size);
  expect(await uploadOmp(link, thisComputer, testedOmpVersion, { asset, installDir: dir })).toBe(`${dir}/omp`);
  expect(readdirSync(dir)).toEqual(["omp"]);
  const version = await runPosixScript(link, `'${dir}/omp' --version`);
  expect(version.stdout).toContain(testedOmpVersion);
  expect(existsSync(`${temp}/.ompanion/install.lock`)).toBe(false);
  expect(await isCached(asset)).toBe(false);
});

test("a failed upload leaves no partial file, and a retry takes over the lock a dropped link left", async () => {
  const dir = `${temp}/bin`;
  const lock = `${temp}/.ompanion/install.lock`;

  // The upload fails while the link is up: the partial file goes and the lock is released.
  const reset = new Error("reset");
  const failing = new FailingUpload(temp, () => {
    throw reset;
  });
  try {
    const asset = await fetchAsset("real");
    const install = uploadOmp(failing, thisComputer, testedOmpVersion, { asset, installDir: dir });
    await expect(install).rejects.toBe(reset);
  } finally {
    await failing.close();
  }
  expect(readdirSync(dir)).toEqual([]);
  expect(existsSync(lock)).toBe(false);

  // The link drops during the upload: nothing can be cleaned up, and the lock stays behind.
  let dropped = false;
  const dropping = new FailingUpload(
    temp,
    () => {
      dropped = true;
      throw new HostLinkException("the link dropped");
    },
    () => dropped,
  );
  try {
    const install = uploadOmp(dropping, thisComputer, testedOmpVersion, {
      asset: await fetchAsset("real"),
      installDir: dir,
    });
    await expect(install).rejects.toBeInstanceOf(HostLinkException);
  } finally {
    await dropping.close();
  }
  expect(readdirSync(dir)).toHaveLength(1);
  expect(existsSync(lock)).toBe(true);

  // Reconnected, the next install takes that lock over at once, removes the partial upload and installs.
  const retry = uploadOmp(link, thisComputer, testedOmpVersion, {
    asset: await fetchAsset("real"),
    installDir: dir,
    lockTimeoutMs: 0,
  });
  expect(await retry).toBe(`${dir}/omp`);
  expect(readdirSync(dir)).toEqual(["omp"]);
  expect(existsSync(lock)).toBe(false);
});

test("the install script refuses a tampered download before running it and removes it", async () => {
  // It would print the expected version, so only the digest check stands between it and the target.
  const requested: string[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch: (request) => {
      requested.push(new URL(request.url).pathname);
      return new Response(`#!/bin/sh\ntouch "${temp}/ran"\necho omp/18.3.1\n`);
    },
  });
  try {
    const dir = `${temp}/bin`;
    const script = posixInstallCommand(macArm, "18.3.1", {
      installDir: dir,
      assetBase: `http://127.0.0.1:${server.port}/v18.3.1/`,
    });
    const result = await runPosixScript(link, script);
    expect(result.exit.code).toBe(1);
    expect(result.stderr).toContain("SHA-256 mismatch");
    expect(requested).toEqual(["/v18.3.1/omp-darwin-arm64"]);
    expect(readdirSync(dir)).toEqual([]);
    expect(existsSync(`${temp}/ran`)).toBe(false);
  } finally {
    await server.stop(true);
  }
});

/** An `omp` at [path] that runs [body] as `sh`. */
async function fakeOmp(path: string, body: string): Promise<string> {
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, `#!/bin/sh\n${body}\n`);
  await chmod(path, 0o755);
  return path;
}

function probe(omp: string, loginPath?: string): HostProbe {
  return hostProbe({
    commandShell: "posix",
    os: "macos",
    kernel: "Darwin",
    arch: "arm64",
    home: temp,
    agentDir: `${temp}/.omp/agent`,
    ompPath: omp,
    loginPath,
  });
}

test("omp update runs the probed omp and resolves `omp` to it, ahead of another one on the login PATH", async () => {
  // omp's updater replaces the `omp` its PATH resolves to; the login PATH stays for brew, bun, npm and gh.
  const omp = await fakeOmp(`${temp}/bin/omp`, 'printf "%s\\n" "$0 $*" "$(command -v omp)" "$PATH"');
  await fakeOmp(`${temp}/brew/omp`, "exit 9");
  const login = `${temp}/brew:/opt/tools`;
  const systemPath = localLink({ HOME: temp, PATH: "/usr/bin:/bin" });
  try {
    const output = await updateOmp(systemPath, probe(omp, login));
    expect(output.split("\n")).toEqual([`${omp} update`, omp, `${temp}/bin:${login}:/usr/bin:/bin`, ""]);
  } finally {
    await systemPath.close();
  }
});

test("a failed omp update throws with what omp said", async () => {
  const omp = await fakeOmp(
    `${temp}/bin/omp`,
    'echo "Current version: 18.3.1"; echo "Update failed: offline" >&2; exit 1',
  );
  const update = updateOmp(link, probe(omp));
  await expect(update).rejects.toBeInstanceOf(HostLinkException);
  await expect(update).rejects.toThrow("Update failed: offline");
});

/**
 * This computer with an isolated [home], whose uploads run and then fail through [fail]. Once [dropped] says so, every
 * exec and file operation fails too, as over an SSH link that went away.
 */
class FailingUpload extends BridgeLink {
  constructor(
    home: string,
    private readonly fail: () => void,
    private readonly dropped: () => boolean = () => false,
  ) {
    super("local", { environment: { HOME: home } });
  }

  override async upload(file: CachedFile, path: string, options: { mode?: number } = {}): Promise<void> {
    await super.upload(file, path, options);
    this.fail();
  }

  override async exec(command: string, options: ExecOptions = {}): Promise<HostProcess> {
    this.throwIfDropped();
    return super.exec(command, options);
  }

  override async files(): Promise<HostFiles> {
    this.throwIfDropped();
    return droppingFiles(await super.files(), () => this.throwIfDropped());
  }

  private throwIfDropped() {
    if (this.dropped()) throw new HostLinkException("the link dropped");
  }
}

function droppingFiles(inner: HostFiles, check: () => void): HostFiles {
  const run = async <T>(operation: () => Promise<T>): Promise<T> => {
    check();
    return operation();
  };
  return {
    stat: (path, options) => run(() => inner.stat(path, options)),
    list: (path) => run(() => inner.list(path)),
    read: (path, options) => run(() => inner.read(path, options)),
    write: (path, bytes, options) => run(() => inner.write(path, bytes, options)),
    mkdir: (path, options) => run(() => inner.mkdir(path, options)),
    remove: (path) => run(() => inner.remove(path)),
    removeDir: (path) => run(() => inner.removeDir(path)),
    rename: (from, to) => run(() => inner.rename(from, to)),
    home: () => run(() => inner.home()),
    close: () => inner.close(),
  };
}
