// The workspace's ordering of late results over files in memory; the rest is file_workspace.e2e.test.ts.
import { expect, test } from "bun:test";
import type { HostFileStat, HostProcess } from "../../core/transport/host_link";
import { type Deferred, deferred } from "../../deferred";
import { settle } from "../../test/live_session";
import { memoryAccess, MemoryFiles, MemoryLink, memoryProbe } from "../../test/memory_host";
import { FileWorkspace } from "./file_workspace";

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
