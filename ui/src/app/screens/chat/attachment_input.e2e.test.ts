// Port of the paste and drop cases of test/screens/chat/composer_test.dart with a desktop shell's paths (shell.info
// `paths`): files copied in the file manager (`shell.clipboardFiles`) and dropped on the window (`shell.drop`), on this
// computer's disk, read through the core.
import { afterAll, beforeAll, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { useCore } from "../../../test/core";
import type { ComposerAttachment } from "../../sessions/composer_attachments";
import { attachmentsFromPaths, readPaste } from "./attachment_input";

useCore();

/** The PNG signature and a few bytes: enough for omp's image types. */
const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);

let dir: string;

beforeAll(async () => {
  dir = await fs.mkdtemp(path.join(os.tmpdir(), "attachment-input-"));
  await fs.writeFile(path.join(dir, "notes.txt"), "notes");
  await fs.writeFile(path.join(dir, "shot.png"), png);
  await fs.mkdir(path.join(dir, "docs"));
});

afterAll(() => fs.rm(dir, { recursive: true, force: true }));

/** What a paste event's clipboard data carries: a copied bitmap, and text. */
function clipboard(files: readonly File[], text: string): DataTransfer {
  const items = files.map((file) => ({
    kind: "file",
    webkitGetAsEntry: () => ({ isDirectory: false, name: file.name }),
    getAsFile: () => file,
  }));
  // Only what readPaste reads of a DataTransfer, which bun does not have.
  return { items, getData: (type: string) => (type === "text/plain" ? text : "") } as unknown as DataTransfer;
}

function describeAttachment(attachment: ComposerAttachment): string {
  switch (attachment.kind) {
    case "FileAttachment":
      return `${attachment.folder ? "folder" : "file"} ${attachment.name} ${attachment.size} ${attachment.path}`;
    case "ImageAttachment":
      return `image ${attachment.image.mimeType} ${attachment.name ?? "null"}`;
    case "TextAttachment":
      return `text ${attachment.text}`;
  }
}

describe("readPaste", () => {
  test("takes the copied files first: files and folders where they are, an image as image content", async () => {
    // Paths the clipboard names that are not on disk (a browser's link) are left out.
    const copied = ["notes.txt", "shot.png", "docs", "no-such-file"].map((name) => path.join(dir, name));
    const bitmap = new File([png], "image.png", { type: "image/png" });
    const pasted = await readPaste(clipboard([bitmap], "notes.txt"), async () => copied);
    expect(pasted?.kind === "PasteAttachments" && pasted.attachments.map(describeAttachment)).toEqual([
      `file notes.txt 5 ${path.join(dir, "notes.txt")}`,
      "image image/png shot.png",
      `folder docs 0 ${path.join(dir, "docs")}`,
    ]);

    // Nothing copied in the file manager: the bitmap.
    const image = await readPaste(clipboard([bitmap], ""), async () => []);
    expect(image?.kind === "PasteAttachments" && image.attachments.map(describeAttachment)).toEqual([
      "image image/png null",
    ]);
  });
});

describe("attachmentsFromPaths", () => {
  test("a drop attaches files and folders; what names nothing on disk attaches nothing", async () => {
    const dropped = await attachmentsFromPaths([path.join(dir, "notes.txt"), path.join(dir, "docs"), "https://example.com/"]);
    expect(dropped.map(describeAttachment)).toEqual([
      `file notes.txt 5 ${path.join(dir, "notes.txt")}`,
      `folder docs 0 ${path.join(dir, "docs")}`,
    ]);
    expect(await attachmentsFromPaths(["https://example.com/"])).toEqual([]);
  });
});
