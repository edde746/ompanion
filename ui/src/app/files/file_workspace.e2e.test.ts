// Port of test/dock/file_workspace_test.dart (and the workspace half of test/dock/file_editor_view_test.dart's reload
// test) on this computer through the core, as the Dart tests run on a LocalLink.
import { afterEach, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { type HostProbe, hostProbe } from "../../core/host/probe";
import type { BridgeLink } from "../../core/transport/bridge_link";
import { HostFileExists, type HostFiles, type HostLink, type HostProcess, type PtyRequest } from "../../core/transport/host_link";
import { localLink, useCore } from "../../test/core";
import { FileChangedOnDisk, maxEditableBytes } from "./file_document";
import { type BrowserRow, FileWorkspace } from "./file_workspace";
import { gitStatusChangeOf } from "./git_status";

useCore();

/** Rows as `ls -F` names: `dir/`, `link@`, `file`. */
function names(rows: readonly BrowserRow[]): [number, string][] {
  return rows.map((row) => {
    switch (row.kind) {
      case "EntryRow": {
        const { name, stat } = row.entry;
        return [row.depth, stat.isLink ? `${name}@` : stat.isDirectory ? `${name}/` : name];
      }
      case "EmptyRow":
        return [row.depth, "(empty)"];
      case "LoadingRow":
        return [row.depth, "(loading)"];
      case "FailedRow":
        return [row.depth, "(failed)"];
    }
  });
}

/** Delegates to a real link and records every command it is asked to run and every file access it opens. */
class RecordingLink implements HostLink {
  readonly commands: string[] = [];
  filesOpened = 0;

  constructor(private readonly inner: HostLink) {}

  get label(): string {
    return this.inner.label;
  }

  get done(): Promise<void> {
    return this.inner.done;
  }

  exec(command: string, options?: { pty?: PtyRequest }): Promise<HostProcess> {
    this.commands.push(command);
    return this.inner.exec(command, options);
  }

  files(): Promise<HostFiles> {
    this.filesOpened++;
    return this.inner.files();
  }

  connect(host: string, port: number) {
    return this.inner.connect(host, port);
  }

  close(): Promise<void> {
    return this.inner.close();
  }
}

let temp: string;
let root: string;
let link: BridgeLink;
let probe: HostProbe;
let workspace: FileWorkspace;

const read = (file: string) => fs.readFileSync(path.join(root, file), "utf8");
const write = (file: string, text: string | Uint8Array) => fs.writeFileSync(path.join(root, file), text);

function git(...args: string[]): void {
  const result = Bun.spawnSync(
    ["git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", ...args],
    { cwd: root },
  );
  expect(result.exitCode, result.stderr.toString()).toBe(0);
}

beforeEach(() => {
  temp = fs.mkdtempSync(path.join(os.tmpdir(), "dock-files-"));
  root = temp;
  write("README.md", "# Demo\nline two\n");
  fs.mkdirSync(path.join(root, "src/lib"), { recursive: true });
  write("src/main.dart", "void main() {}\n");
  write("src/lib/a.dart", "");
  fs.mkdirSync(path.join(root, "docs"));
  link = localLink({ HOME: root });
  probe = hostProbe({ commandShell: "posix", os: "macos", kernel: "Darwin", arch: "arm64", home: root, agentDir: `${root}/.omp/agent` });
  workspace = new FileWorkspace();
  workspace.connect = async () => [link, probe];
});

afterEach(async () => {
  workspace.dispose();
  await link.close();
  fs.rmSync(temp, { recursive: true, force: true });
});

test("browses the session directory lazily, folders first; expanded folders nest", async () => {
  await workspace.follow(root);
  expect(workspace.root()).toBe(root);
  expect(names(workspace.rows())).toEqual([
    [0, "docs/"],
    [0, "src/"],
    [0, "README.md"],
  ]);

  await workspace.toggle(`${root}/src`);
  await workspace.toggle(`${root}/docs`);
  expect(names(workspace.rows())).toEqual([
    [0, "docs/"],
    [1, "(empty)"],
    [0, "src/"],
    [1, "lib/"],
    [1, "main.dart"],
    [0, "README.md"],
  ]);

  await workspace.toggle(`${root}/src`);
  expect(names(workspace.rows())).toEqual([
    [0, "docs/"],
    [1, "(empty)"],
    [0, "src/"],
    [0, "README.md"],
  ]);

  // The same session directory again keeps where the user navigated to.
  await workspace.openDir(`${root}/src`);
  await workspace.follow(root);
  expect(workspace.root()).toBe(`${root}/src`);
});

test("paths from the transcript resolve against the session directory and home", async () => {
  expect(await workspace.resolve("~/README.md", { cwd: "/elsewhere" })).toBe(`${root}/README.md`);
  await workspace.follow(root);
  expect(await workspace.resolve("src/main.dart", { cwd: root })).toBe(`${root}/src/main.dart`);
  expect(await workspace.resolve("/etc/hosts", { cwd: root })).toBe("/etc/hosts");
  expect(await workspace.resolve("C:\\x\\y.txt", { cwd: root })).toBe("/C:/x/y.txt");
});

test("edit and save round trip; a change made elsewhere since loading is a conflict", async () => {
  await workspace.follow(root);
  await workspace.open(`${root}/README.md`, { line: 2 });
  const document = workspace.current();
  if (document === undefined) throw new Error("no document open");
  expect(document.pendingLine).toBe(2);
  expect(document.text()).toBe("# Demo\nline two\n");
  expect(document.dirty()).toBe(false);

  document.setText("# Demo\nedited\n");
  expect(document.dirty()).toBe(true);
  await workspace.save(document);
  expect(read("README.md")).toBe("# Demo\nedited\n");
  expect(document.dirty()).toBe(false);

  write("README.md", "changed on the machine, and longer\n");
  document.setText("mine\n");
  await expect(workspace.save(document)).rejects.toBeInstanceOf(FileChangedOnDisk);
  expect(read("README.md")).toBe("changed on the machine, and longer\n");

  await workspace.save(document, { force: true });
  expect(read("README.md")).toBe("mine\n");

  fs.rmSync(path.join(root, "README.md"));
  document.setText("again\n");
  const conflict = await workspace.save(document).catch((error: unknown) => error);
  expect(conflict).toBeInstanceOf(FileChangedOnDisk);
  expect((conflict as FileChangedOnDisk).deleted).toBe(true);
});

test("reopening an open file reuses its document; CRLF files keep their line breaks", async () => {
  write("windows.txt", "one\r\ntwo\r\n");
  await workspace.follow(root);
  await workspace.open(`${root}/windows.txt`);
  const document = workspace.current();
  workspace.showBrowser();
  await workspace.open(`${root}/windows.txt`, { line: 1 });
  expect(workspace.current()).toBe(document);
  expect(workspace.documents()).toHaveLength(1);

  document?.setText("one\ntwo\nthree\n");
  if (document !== undefined) await workspace.save(document);
  expect(read("windows.txt")).toBe("one\r\ntwo\r\nthree\r\n");
});

test("saving keeps the line break most lines use; a reload takes the one the file has now", async () => {
  write("mixed.txt", "one\ntwo\r\nthree\nfour\n");
  await workspace.follow(root);
  await workspace.open(`${root}/mixed.txt`);
  const mixed = workspace.current();
  if (mixed === undefined) throw new Error("no document open");
  mixed.setText("one\ntwo\nthree\nfour\nfive\n");
  await workspace.save(mixed);
  expect(read("mixed.txt")).toBe("one\ntwo\nthree\nfour\nfive\n");

  write("converted.txt", "one\ntwo\n");
  await workspace.open(`${root}/converted.txt`);
  const converted = workspace.current();
  if (converted === undefined) throw new Error("no document open");
  write("converted.txt", "one\r\ntwo\r\n");
  await workspace.reload(converted);
  converted.setText("one\ntwo\nthree\n");
  await workspace.save(converted);
  expect(read("converted.txt")).toBe("one\r\ntwo\r\nthree\r\n");
});

test("opening a file twice at once, as a double click does, opens one document", async () => {
  await workspace.follow(root);
  await Promise.all([workspace.open(`${root}/README.md`), workspace.open(`${root}/README.md`)]);
  expect(workspace.documents()).toHaveLength(1);
});

test("large, binary and non-UTF-8 files open read-only", async () => {
  write("big.log", new Uint8Array(maxEditableBytes + 10).fill(0x61));
  write("image.png", new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 0, 0]));
  write("latin1.txt", new Uint8Array([0x63, 0x61, 0x66, 0xe9]));
  await workspace.follow(root);
  for (const [name, reason] of [
    ["big.log", "tooLarge"],
    ["image.png", "binary"],
    ["latin1.txt", "notUtf8"],
  ] as const) {
    await workspace.open(`${root}/${name}`);
    expect(workspace.current()?.readOnlyReason()).toBe(reason);
  }
  expect(workspace.documents()[0]?.text().length).toBe(maxEditableBytes);
  const current = workspace.current();
  if (current === undefined) throw new Error("no document open");
  await expect(workspace.save(current)).rejects.toThrow("read-only");
});

test("create, rename and delete; open documents follow a rename and close with a delete", async () => {
  await workspace.follow(root);
  await workspace.createFile(root, "notes.txt");
  expect(fs.existsSync(path.join(root, "notes.txt"))).toBe(true);
  expect(workspace.current()?.path()).toBe(`${root}/notes.txt`);
  await expect(workspace.createFile(root, "notes.txt")).rejects.toBeInstanceOf(HostFileExists);

  await workspace.createFolder(`${root}/docs`, "guides");
  expect(fs.statSync(path.join(root, "docs/guides")).isDirectory()).toBe(true);

  await workspace.open(`${root}/src/lib/a.dart`);
  const document = workspace.current();
  await workspace.rename(`${root}/src`, "source");
  expect(document?.path()).toBe(`${root}/source/lib/a.dart`);
  expect(fs.statSync(path.join(root, "source/lib")).isDirectory()).toBe(true);
  await expect(workspace.rename(`${root}/source`, "docs")).rejects.toBeInstanceOf(HostFileExists);

  await workspace.delete(`${root}/source`);
  expect(fs.existsSync(path.join(root, "source"))).toBe(false);
  expect(workspace.documents().map((open) => open.path())).toEqual([`${root}/notes.txt`]);
  expect(names(workspace.rows()).map(([, name]) => name)).toEqual(["docs/", "notes.txt", "README.md"]);
});

test("renaming an expanded folder keeps it and its expanded subfolders listed", async () => {
  await workspace.follow(root);
  await workspace.toggle(`${root}/src`);
  await workspace.toggle(`${root}/src/lib`);
  await workspace.rename(`${root}/src`, "source");
  expect(names(workspace.rows())).toEqual([
    [0, "docs/"],
    [0, "source/"],
    [1, "lib/"],
    [2, "a.dart"],
    [1, "main.dart"],
    [0, "README.md"],
  ]);
});

test("a rename that changes only the case goes through; another file of that name is never replaced", async () => {
  write("notes.txt", "mine\n");
  // macOS and Windows file systems ignore case by default; Linux ones do not.
  const ignoresCase = fs.existsSync(path.join(root, "NOTES.txt"));
  await workspace.follow(root);
  if (ignoresCase) {
    await workspace.rename(`${root}/notes.txt`, "NOTES.txt");
    expect(fs.readdirSync(root)).toContain("NOTES.txt");
    expect(names(workspace.rows()).map(([, name]) => name)).toContain("NOTES.txt");
  } else {
    write("NOTES.txt", "other\n");
    await expect(workspace.rename(`${root}/notes.txt`, "NOTES.txt")).rejects.toBeInstanceOf(HostFileExists);
    expect(read("NOTES.txt")).toBe("other\n");
  }
});

test("a symbolic link is listed as a link and deleted as one, never what it points to", async () => {
  const outside = fs.mkdtempSync(path.join(os.tmpdir(), "dock-files-outside-"));
  try {
    fs.writeFileSync(path.join(outside, "keep.txt"), "keep\n");
    fs.symlinkSync(outside, path.join(root, "shared"));
    fs.symlinkSync(outside, path.join(root, "src/inner"));
    fs.symlinkSync(path.join(root, "missing"), path.join(root, "gone"));

    await workspace.follow(root);
    await workspace.toggle(`${root}/src`);
    expect(names(workspace.rows())).toEqual([
      [0, "docs/"],
      [0, "src/"],
      [1, "lib/"],
      [1, "inner@"],
      [1, "main.dart"],
      [0, "gone@"],
      [0, "README.md"],
      [0, "shared@"],
    ]);

    // Opening follows the link: it browses the directory it points to.
    await workspace.open(`${root}/shared`);
    expect(names(workspace.rows())).toEqual([[0, "keep.txt"]]);
    await workspace.openDir(root);

    await workspace.delete(`${root}/shared`);
    expect(fs.existsSync(path.join(root, "shared")) || isLink(path.join(root, "shared"))).toBe(false);
    expect(fs.readFileSync(path.join(outside, "keep.txt"), "utf8")).toBe("keep\n");
    await workspace.delete(`${root}/src`);
    expect(fs.existsSync(path.join(root, "src"))).toBe(false);
    expect(fs.readFileSync(path.join(outside, "keep.txt"), "utf8")).toBe("keep\n");
    await workspace.delete(`${root}/gone`);
    expect(isLink(path.join(root, "gone"))).toBe(false);
    expect(names(workspace.rows())).toEqual([
      [0, "docs/"],
      [0, "README.md"],
    ]);
  } finally {
    fs.rmSync(outside, { recursive: true, force: true });
  }
});

function isLink(file: string): boolean {
  try {
    return fs.lstatSync(file).isSymbolicLink();
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return false;
    throw error;
  }
}

test("git status and diff of the browsed repository", async () => {
  git("init", "-q");
  git("add", "README.md", "src/main.dart");
  git("commit", "-q", "-m", "init");
  write("README.md", "# Demo\nline two\nline three\n");

  await workspace.follow(root);
  await workspace.refreshGit();
  const status = workspace.git();
  if (status === undefined) throw new Error("no git status");
  expect(gitStatusChangeOf(status, `${root}/README.md`)).toBe("modified");
  expect(gitStatusChangeOf(status, `${root}/src/lib/a.dart`)).toBe("untracked");
  expect(gitStatusChangeOf(status, `${root}/src/main.dart`)).toBeUndefined();
  expect(status.dirty.has(`${root}/src`)).toBe(true);

  expect(await workspace.diff(`${root}/README.md`)).toContain("+line three");
  expect(await workspace.diff(`${root}/src/main.dart`)).toBe("");

  // From a subdirectory the repository root is still the browsed path's ancestor, not git's real path.
  await workspace.openDir(`${root}/docs`);
  await workspace.refreshGit();
  expect(workspace.git()?.root).toBe(root);
  await workspace.openDir(os.tmpdir());
  await workspace.refreshGit();
  expect(workspace.git()).toBeUndefined();
});

test("reloading from disk while the git diff shows: the text and a fresh diff follow the file", async () => {
  write("README.md", "# Demo\n");
  git("init", "-q");
  git("add", "README.md");
  git("commit", "-q", "-m", "init");
  write("README.md", "# Demo\nchanged\n");
  await workspace.follow(root);
  await workspace.open(`${root}/README.md`);
  const document = workspace.current();
  if (document === undefined) throw new Error("no document open");
  expect(await workspace.diff(document.path())).toContain("+changed");

  write("README.md", "# Demo\nchanged again\n");
  await workspace.reload(document);
  expect(document.text()).toContain("again");
  expect(document.revision()).toBe(1);
  expect(await workspace.diff(document.path())).toContain("+changed again");
});

test("git gets paths inside an sh script, never on the command line the login shell parses", async () => {
  // fish reads \' inside single quotes as an escaped quote: sh quoting on its command line can be broken out of.
  const name = "it\\'s;touch pwned;#";
  fs.mkdirSync(path.join(root, name));
  write(`${name}/notes.txt`, "one\n");
  git("init", "-q");
  git("add", ".");
  git("commit", "-q", "-m", "init");
  write(`${name}/notes.txt`, "two\n");
  const recording = new RecordingLink(link);
  const browser = new FileWorkspace();
  browser.connect = async () => [recording, probe];
  try {
    await browser.openDir(`${root}/${name}`);
    await browser.refreshGit();
    const status = browser.git();
    expect(status === undefined ? undefined : gitStatusChangeOf(status, `${root}/${name}/notes.txt`)).toBe("modified");
    expect(await browser.diff(`${root}/${name}/notes.txt`)).toContain("+two");
    expect(recording.commands.length).toBeGreaterThan(0);
    expect(new Set(recording.commands)).toEqual(new Set(["sh -s"]));
  } finally {
    browser.dispose();
  }
});

test("file access is opened once per link, however many operations start at the same time", async () => {
  const first = new RecordingLink(link);
  let current: HostLink = first;
  const browser = new FileWorkspace();
  browser.connect = async () => [current, probe];
  try {
    await Promise.all([browser.follow(root), browser.open(`${root}/README.md`)]);
    await browser.openDir(root);
    await browser.toggle(`${root}/src`);
    await browser.toggle(`${root}/docs`);
    expect(first.filesOpened).toBe(1);

    // A reconnect: the next refresh lists three directories over one new file access.
    const second = new RecordingLink(link);
    current = second;
    await browser.refresh();
    expect(second.filesOpened).toBe(1);
  } finally {
    browser.dispose();
  }
});
