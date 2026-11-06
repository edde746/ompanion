// The parts of test/dock/file_workspace_test.dart that need no machine; the rest is file_workspace.e2e.test.ts.
import { expect, test } from "bun:test";
import type { HostDirEntry, HostFiles, HostFileStat } from "../../core/transport/host_link";
import { type Deferred, deferred } from "../../deferred";
import { MemoryFiles } from "../../test/memory_host";
import { decodeFileText, FileChangedOnDisk, FileDocument, lineBreakOf, maxEditableBytes } from "./file_document";

const encode = (text: string) => new TextEncoder().encode(text);
const decode = (bytes: Uint8Array | undefined) => new TextDecoder("utf-8", { ignoreBOM: true }).decode(bytes);

/**
 * A file that reports size 0 and never ends, like `/dev/zero` or a `/proc` file over SFTP: a read without a length goes
 * on until the data runs out; here that is 3 MiB. Records the lengths asked for.
 */
class EndlessFiles implements HostFiles {
  readonly lengths: (number | undefined)[] = [];

  async stat(): Promise<HostFileStat | null> {
    return { size: 0, isDirectory: false, isLink: false };
  }

  async read(_path: string, options: { length?: number } = {}): Promise<Uint8Array> {
    this.lengths.push(options.length);
    return new Uint8Array(options.length ?? 3 << 20).fill(0x61);
  }

  list(): Promise<HostDirEntry[]> {
    throw new Error("not a directory");
  }
  write(): Promise<void> {
    throw new Error("read-only");
  }
  mkdir(): Promise<void> {
    throw new Error("read-only");
  }
  remove(): Promise<void> {
    throw new Error("read-only");
  }
  removeDir(): Promise<void> {
    throw new Error("read-only");
  }
  rename(): Promise<void> {
    throw new Error("read-only");
  }
  home(): Promise<string> {
    throw new Error("no home");
  }
  async close(): Promise<void> {}
}

test("a file that reports size 0 (a device, /proc) is read only up to the editable limit", async () => {
  const files = new EndlessFiles();
  const document = await FileDocument.load(files, "/dev/zero");
  expect(files.lengths).toEqual([maxEditableBytes + 1]);
  expect(document.readOnlyReason()).toBe("tooLarge");
  expect(document.text().length).toBe(maxEditableBytes);
});

test("binary, non-UTF-8 and truncated bytes are read-only; a byte order mark stays in the text", () => {
  expect(decodeFileText(new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0, 0, 0]), { truncated: false })).toEqual(["", "binary"]);
  expect(decodeFileText(new Uint8Array([0x63, 0x61, 0x66, 0xe9]), { truncated: false })).toEqual(["caf\uFFFD", "notUtf8"]);
  expect(decodeFileText(encode("abc"), { truncated: true })).toEqual(["abc", "tooLarge"]);
  expect(decodeFileText(encode("\uFEFFhello"), { truncated: false })).toEqual(["\uFEFFhello", undefined]);
  // A NUL past the first 8 KiB is text that happens to hold one.
  const late = new Uint8Array(9000).fill(0x61);
  late[8500] = 0;
  expect(decodeFileText(late, { truncated: false })[1]).toBeUndefined();
});

test("the line break most lines end with", () => {
  expect(lineBreakOf("one\ntwo\n")).toBe("\n");
  expect(lineBreakOf("one\r\ntwo\r\n")).toBe("\r\n");
  expect(lineBreakOf("one\rtwo\r")).toBe("\r");
  expect(lineBreakOf("one\ntwo\r\nthree\nfour\n")).toBe("\n");
  expect(lineBreakOf("no break")).toBe("\n");
});

test("editing back to the saved text is clean again; saving writes the file's line break", async () => {
  const files = new MemoryFiles({ "/w/windows.txt": "one\r\ntwo\r\n" });
  const document = await FileDocument.load(files, "/w/windows.txt");
  expect(document.text()).toBe("one\ntwo\n");
  document.setText("one\ntwo\nthree\n");
  expect(document.dirty()).toBe(true);
  document.setText("one\r\ntwo\r\n");
  expect(document.dirty()).toBe(false);

  document.setText("one\ntwo\nthree\n");
  await document.save(async () => files);
  expect(decode(files.files.get("/w/windows.txt"))).toBe("one\r\ntwo\r\nthree\r\n");
  expect(document.dirty()).toBe(false);
  expect(document.saving()).toBe(false);
});

test("a change on the machine since loading is a conflict; force overwrites it", async () => {
  const files = new MemoryFiles({ "/w/notes.txt": "one\n" });
  const document = await FileDocument.load(files, "/w/notes.txt");
  files.put("/w/notes.txt", encode("theirs\n"));
  document.setText("mine\n");
  const conflict = await document.save(async () => files).catch((error: unknown) => error);
  expect(conflict).toBeInstanceOf(FileChangedOnDisk);
  expect((conflict as FileChangedOnDisk).deleted).toBe(false);
  expect(decode(files.files.get("/w/notes.txt"))).toBe("theirs\n");
  expect(document.dirty()).toBe(true);

  await document.save(async () => files, { force: true });
  expect(decode(files.files.get("/w/notes.txt"))).toBe("mine\n");

  await files.remove("/w/notes.txt");
  document.setText("again\n");
  const deleted = await document.save(async () => files).catch((error: unknown) => error);
  expect((deleted as FileChangedOnDisk).deleted).toBe(true);
});

/** Writes wait for {@link gate} while it is set. */
class GatedFiles extends MemoryFiles {
  gate: Deferred<void> | undefined;

  override async write(path: string, bytes: Uint8Array, options: { append?: boolean } = {}): Promise<void> {
    await this.gate?.promise;
    return super.write(path, bytes, options);
  }
}

test("a save is saving from the call, and a reload during it reads the file once it is written", async () => {
  const files = new GatedFiles({ "/w/notes.txt": "old\n" });
  const document = await FileDocument.load(files, "/w/notes.txt");
  document.setText("mine\n");
  const access = deferred<HostFiles>();
  files.gate = deferred<void>();

  const saving = document.save(() => access.promise);
  expect(document.saving()).toBe(true);
  access.resolve(files);
  const reloading = document.reload(async () => files);
  files.gate.resolve();
  await Promise.all([saving, reloading]);

  expect(document.text()).toBe("mine\n");
  expect(document.dirty()).toBe(false);
  expect(document.saving()).toBe(false);
  // The stat is the written file's, so the next save is no conflict.
  document.setText("again\n");
  await document.save(async () => files);
  expect(decode(files.files.get("/w/notes.txt"))).toBe("again\n");
});
