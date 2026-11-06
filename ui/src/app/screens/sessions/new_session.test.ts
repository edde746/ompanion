import { expect, test } from "bun:test";
import { flush } from "solid-js";
import type { SessionSummary } from "../../../core/host/session_listing";
import { hostProbe, hostProbeScratchDirs } from "../../../core/host/probe";
import type { RpcModel } from "../../../core/rpc/results";
import type { HostDirEntry, HostFiles } from "../../../core/transport/host_link";
import { type Deferred, deferred } from "../../../deferred";
import { MemoryFiles, MemoryLink, memoryProbe } from "../../../test/memory_host";
import { t } from "../../i18n/i18n";
import {
  DirectoryBrowser,
  expandHome,
  modelName,
  parentDirectory,
  recentProjects,
  sessionDirectory,
} from "./new_session";

const probe = memoryProbe("/home/u");

/** Files that record whether they were closed. */
class ClosingFiles extends MemoryFiles {
  closed = false;

  override async close(): Promise<void> {
    this.closed = true;
  }
}

/** A link whose file channel opens only once `hold` resolves. */
class HeldLink extends MemoryLink {
  readonly hold = deferred<void>();

  override async files(): Promise<HostFiles> {
    await this.hold.promise;
    return this.memory;
  }
}

/** Files whose listing of a held directory answers only once the test releases it. */
class HeldListFiles extends MemoryFiles {
  private readonly holds = new Map<string, Deferred<void>>();

  hold(path: string): Deferred<void> {
    const hold = deferred<void>();
    this.holds.set(path, hold);
    return hold;
  }

  override async list(path: string): Promise<HostDirEntry[]> {
    await this.holds.get(path)?.promise;
    return super.list(path);
  }
}

function summary(cwd: string | undefined, index: number): SessionSummary {
  return { path: `/home/u/.omp/agent/sessions/${index}.jsonl`, size: 1, modifiedMs: index, id: `s${index}`, cwd };
}

test("recent projects skip omp's temporary directories and repeats, newest first, eight at most", () => {
  const scratch = hostProbeScratchDirs(probe);
  const listed = ["/tmp", "/home/u/alpha", "/home/u/.cache/deep/beta", undefined, "/home/u/alpha", "/home/u/tmp"];
  expect(recentProjects(listed.map(summary), scratch)).toEqual(["/home/u/alpha", "/home/u/.cache/deep/beta"]);

  const many = Array.from({ length: 12 }, (_, index) => summary(`/home/u/p${index}`, index));
  expect(recentProjects(many, scratch)).toEqual(Array.from({ length: 8 }, (_, index) => `/home/u/p${index}`));
});

test("a leading ~ in the directory field is the machine's home", () => {
  expect(expandHome("~", "/home/u")).toBe("/home/u");
  expect(expandHome("~/code", "/home/u")).toBe("/home/u/code");
  expect(expandHome("~\\code", "C:\\Users\\u")).toBe("C:\\Users\\u\\code");
  expect(expandHome("~other/code", "/home/u")).toBe("~other/code");
  expect(expandHome("~/code", undefined)).toBe("~/code");
});

test("without a folder the session works where omp started in the home directory does: ~/tmp before /tmp", async () => {
  const files = new ClosingFiles({ "/tmp/a": "x", "/home/u/tmp/b": "x" }, "/home/u");
  const link = new MemoryLink(files);
  expect(await sessionDirectory(link, { probe, noFolder: true, typed: "", machine: "box" })).toEqual({
    cwd: "/home/u/tmp",
  });
  expect(files.closed).toBe(true);

  const onlyTmp = new MemoryLink(new MemoryFiles({ "/tmp/a": "x" }, "/home/u"));
  expect(await sessionDirectory(onlyTmp, { probe, noFolder: true, typed: "", machine: "box" })).toEqual({
    cwd: "/tmp",
  });
});

test("without a folder and none of the temporary directories, the error names every one of them", async () => {
  const link = new MemoryLink(new MemoryFiles({}, "/home/u"));
  const result = await sessionDirectory(link, { probe, noFolder: true, typed: "", machine: "box" });
  expect(result).toEqual({
    error: t.sessions.noTempDirectory({ paths: "/home/u/tmp, /tmp, /var/tmp", machine: "box" }),
  });
});

test("a typed folder must be a directory on the machine", async () => {
  const link = new MemoryLink(new MemoryFiles({ "/home/u/project/README.md": "x" }, "/home/u"));
  const options = { probe, noFolder: false, machine: "box" };
  expect(await sessionDirectory(link, { ...options, typed: "/home/u/project" })).toEqual({ cwd: "/home/u/project" });
  expect(await sessionDirectory(link, { ...options, typed: "/home/u/project/README.md" })).toEqual({
    error: t.sessions.notADirectory({ path: "/home/u/project/README.md", machine: "box" }),
  });
});

test("a Windows folder is checked in SFTP path space and kept host-native", async () => {
  const windows = hostProbe({
    commandShell: "powershell",
    os: "windows",
    kernel: "Windows_NT",
    arch: "x64",
    home: "C:\\Users\\u",
    agentDir: "C:\\Users\\u\\.omp\\agent",
  });
  const link = new MemoryLink(new MemoryFiles({ "/C:/work/app/x": "x" }, "/C:/Users/u"));
  const options = { probe: windows, noFolder: false, typed: "C:\\work\\app", machine: "pc" };
  expect(await sessionDirectory(link, options)).toEqual({ cwd: "C:\\work\\app" });
});

test("the model field names a listed model with its provider and thinking level, else shows the selector", () => {
  const model = (id: string, name: string): RpcModel => ({
    raw: {},
    provider: "fake",
    id,
    name,
    reasoning: true,
    input: ["text"],
  });
  const models = [model("fast", "Fast"), model("reasoning", "Reasoning")];
  expect(modelName(models, "fake/fast")).toBe("Fast · fake");
  expect(modelName(models, "fake/reasoning:high")).toBe("Reasoning · fake · high");
  expect(modelName(models, "other/model")).toBe("other/model");
});

test("the directory picker goes up to the root, and stops at a Windows drive", () => {
  expect(parentDirectory("/home/u/code")).toBe("/home/u");
  expect(parentDirectory("/home/u/code/")).toBe("/home/u");
  expect(parentDirectory("/home")).toBe("/");
  expect(parentDirectory("/")).toBeUndefined();
  expect(parentDirectory("/C:/Users")).toBe("/C:");
  expect(parentDirectory("/C:")).toBeUndefined();
});

test("the directory picker lists the start directory's subdirectories, sorted without regard to case", async () => {
  const files = new MemoryFiles(
    { "/home/u/code/b/x": "x", "/home/u/code/A/x": "x", "/home/u/code/c.txt": "x", "/home/u/code/.git/x": "x" },
    "/home/u",
  );
  const browser = new DirectoryBrowser(() => new MemoryLink(files));
  await browser.open("/home/u/code");
  flush();
  expect(browser.path()).toBe("/home/u/code");
  expect(browser.entries()).toEqual([".git", "A", "b"]);

  const missing = new DirectoryBrowser(() => new MemoryLink(files));
  await missing.open("/home/u/gone");
  flush();
  expect(missing.path()).toBe("/home/u");
});

test("a directory picker closed while its file channel opens closes the channel", async () => {
  const files = new ClosingFiles({}, "/home/u");
  const link = new HeldLink(files);
  const browser = new DirectoryBrowser(() => link);
  const opening = browser.open(undefined);
  await browser.dispose();
  link.hold.resolve();
  await opening;
  expect(files.closed).toBe(true);
});

test("the directory picker shows the directory navigated to last when an earlier listing answers later", async () => {
  const files = new HeldListFiles({ "/home/u/a/b/x": "x" }, "/home/u");
  const browser = new DirectoryBrowser(() => new MemoryLink(files));
  await browser.open("/home/u/a");

  const child = files.hold("/home/u/a/b");
  const entering = browser.enter("b");
  await browser.list("/home/u");
  child.resolve();
  await entering;
  flush();
  expect(browser.path()).toBe("/home/u");
  expect(browser.entries()).toEqual(["a"]);

  const missing = files.hold("/home/u/gone");
  const failing = browser.enter("gone");
  await browser.list("/home/u/a");
  missing.resolve();
  await failing;
  flush();
  expect(browser.error()).toBeUndefined();
  expect(browser.path()).toBe("/home/u/a");
  expect(browser.entries()).toEqual(["b"]);
});

test("a directory picker closed while it lists keeps the directory it showed", async () => {
  const files = new HeldListFiles({ "/home/u/a/x": "x" }, "/home/u");
  const browser = new DirectoryBrowser(() => new MemoryLink(files));
  await browser.open(undefined);
  const child = files.hold("/home/u/a");
  const entering = browser.enter("a");
  await browser.dispose();
  child.resolve();
  await entering;
  flush();
  expect(browser.path()).toBe("/home/u");
});

test("a directory picker on a machine that is not connected says why", async () => {
  const browser = new DirectoryBrowser(() => {
    throw new Error("not connected; call connectAndProbe() first");
  });
  await browser.open(undefined);
  flush();
  expect(browser.error()).toBe("Error: not connected; call connectAndProbe() first");
});
