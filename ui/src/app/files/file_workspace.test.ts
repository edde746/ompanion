// The workspace's ordering of late results over files in memory; the rest is file_workspace.e2e.test.ts.
import { expect, test } from "bun:test";
import type { HostFileStat, HostProcess } from "../../core/transport/host_link";
import { type Deferred, deferred } from "../../deferred";
import { settle } from "../../test/live_session";
import { memoryAccess, MemoryFiles, MemoryLink, memoryProbe } from "../../test/memory_host";
import { FileWorkspace, shownAfterClose } from "./file_workspace";

/** A link whose every command succeeds with no output, so git reports a clean repository at the browsed directory. */
class CleanGitLink extends MemoryLink {
  /** While set, commands started now end only once it resolves. */
  held: Deferred<void> | undefined;

  override async exec(): Promise<HostProcess> {
    const held = this.held;
    const process = await super.exec();
    return { ...process, exit: (held?.promise ?? Promise.resolve()).then(() => ({ code: 0 })) };
  }
}

/** Stats of `slow` wait for {@link gate}. */
class SlowFiles extends MemoryFiles {
  readonly gate = deferred<void>();

  constructor(
    contents: Readonly<Record<string, string>>,
    private readonly slow: string,
  ) {
    super(contents);
  }

  override async stat(path: string): Promise<HostFileStat | null> {
    if (path === this.slow) await this.gate.promise;
    return super.stat(path);
  }
}

test("a git status that comes back late is not shown for the directory browsed since", async () => {
  const files = new MemoryFiles({ "/w/a/x.txt": "x", "/w/b/y.txt": "y" });
  const link = new CleanGitLink(files);
  const workspace = new FileWorkspace();
  workspace.connect = async () => [link, memoryProbe()];

  const late = (link.held = deferred<void>());
  await workspace.openDir("/w/a");
  await settle();
  expect(workspace.git()).toBeUndefined();
  link.held = undefined;
  await workspace.openDir("/w/b");
  await settle();
  expect(workspace.git()?.root).toBe("/w/b");

  late.resolve();
  await settle();
  expect(workspace.git()?.root).toBe("/w/b");
});

test("a file that opens late does not replace what the user chose to show meanwhile", async () => {
  const files = new SlowFiles({ "/w/slow.txt": "slow", "/w/quick.txt": "quick" }, "/w/slow.txt");
  const workspace = new FileWorkspace();
  workspace.connect = memoryAccess(files);

  const slow = workspace.open("/w/slow.txt");
  await workspace.open("/w/quick.txt");
  expect(workspace.current()?.path()).toBe("/w/quick.txt");
  files.gate.resolve();
  await slow;

  expect(workspace.current()?.path()).toBe("/w/quick.txt");
  expect(workspace.documents().map((document) => document.path())).toEqual(["/w/quick.txt", "/w/slow.txt"]);
});

test("opening an already-open file focuses it instead of duplicating", async () => {
  const files = new MemoryFiles({ "/w/a.txt": "a", "/w/b.txt": "b" });
  const workspace = new FileWorkspace();
  workspace.connect = memoryAccess(files);
  await workspace.open("/w/a.txt");
  const a = workspace.current();
  await workspace.open("/w/b.txt");
  const b = workspace.current();
  if (a === undefined || b === undefined) throw new Error("open failed");
  expect(workspace.documents()).toEqual([a, b]);
  await workspace.open("/w/a.txt");
  expect(workspace.documents()).toEqual([a, b]);
  expect(workspace.current()).toBe(a);
});

test("closing the active file shows its neighbour; closing the last returns to the list", async () => {
  const files = new MemoryFiles({ "/w/a.txt": "a", "/w/b.txt": "b", "/w/c.txt": "c" });
  const workspace = new FileWorkspace();
  workspace.connect = memoryAccess(files);
  await workspace.open("/w/a.txt");
  const a = workspace.current();
  await workspace.open("/w/b.txt");
  const b = workspace.current();
  await workspace.open("/w/c.txt");
  const c = workspace.current();
  if (a === undefined || b === undefined || c === undefined) throw new Error("open failed");

  workspace.closeDocument(c);
  expect(workspace.current()).toBe(b);
  expect(workspace.documents()).toEqual([a, b]);

  workspace.show(a);
  workspace.closeDocument(a);
  expect(workspace.current()).toBe(b);
  expect(workspace.documents()).toEqual([b]);

  workspace.closeDocument(b);
  expect(workspace.current()).toBeUndefined();
  expect(workspace.documents()).toEqual([]);
});

test("closing a file that is not shown leaves the shown file", async () => {
  const files = new MemoryFiles({ "/w/a.txt": "a", "/w/b.txt": "b", "/w/c.txt": "c" });
  const workspace = new FileWorkspace();
  workspace.connect = memoryAccess(files);
  await workspace.open("/w/a.txt");
  const a = workspace.current();
  await workspace.open("/w/b.txt");
  await workspace.open("/w/c.txt");
  const c = workspace.current();
  if (a === undefined || c === undefined) throw new Error("open failed");
  workspace.closeDocument(a);
  expect(workspace.current()).toBe(c);
  expect(workspace.documents().map((document) => document.path())).toEqual(["/w/b.txt", "/w/c.txt"]);
});

test("shownAfterClose picks the neighbour of the active file and none when the last file closes", () => {
  expect(shownAfterClose(1, 0, 0)).toBeUndefined();
  expect(shownAfterClose(3, 0, 0)).toBe(0);
  expect(shownAfterClose(3, 1, 1)).toBe(1);
  expect(shownAfterClose(3, 2, 2)).toBe(1);
  expect(shownAfterClose(3, 0, 2)).toBe(1);
  expect(shownAfterClose(3, 2, 0)).toBe(0);
  expect(shownAfterClose(3, 1, undefined)).toBeUndefined();
});
