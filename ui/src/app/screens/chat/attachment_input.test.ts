// Port of the paste cases of test/screens/chat/composer_test.dart, as the page reads a paste itself (the browser,
// phones): the paste event's clipboard data. The same order with a desktop shell's copied paths, and the drops, read
// files through the core: attachment_input.e2e.test.ts. iOS's menu Paste and an Android keyboard's images come from
// the shell as files in its cache (`shell.pasteFiles`).
import { describe, expect, test } from "bun:test";
import { base64Encode } from "../../../core/util/base64";
import type { ComposerAttachment } from "../../sessions/composer_attachments";
import { attachmentsFromPasted, type Paste, readPaste } from "./attachment_input";

/** The PNG signature and a few bytes: enough for omp's image types. */
const png = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);

/** What a paste event's clipboard data carries: files and folders (by name), and text. */
function clipboard(items: readonly (File | { readonly folder: string })[], text = ""): DataTransfer {
  const entries = items.map((item) => ({
    kind: "file",
    webkitGetAsEntry: () =>
      item instanceof File ? { isDirectory: false, name: item.name } : { isDirectory: true, name: item.folder },
    getAsFile: () => (item instanceof File ? item : null),
  }));
  // Only what readPaste reads of a DataTransfer, which bun does not have.
  return { items: entries, getData: (type: string) => (type === "text/plain" ? text : "") } as unknown as DataTransfer;
}

function describeAttachment(attachment: ComposerAttachment): string {
  switch (attachment.kind) {
    case "FileAttachment":
      return `file ${attachment.name} ${attachment.size}`;
    case "ImageAttachment":
      return `image ${attachment.image.mimeType} ${attachment.name ?? "null"}`;
    case "TextAttachment":
      return `text ${attachment.text}`;
  }
}

function describePaste(paste: Paste | undefined): string[] | string | undefined {
  if (paste?.kind === "PasteText") return paste.text;
  return paste?.attachments.map(describeAttachment);
}

describe("readPaste", () => {
  test("takes copied files first, then an image, then text; a large text becomes a chip", async () => {
    const files = [new File(["notes"], "notes.txt"), new File([png], "shot.png"), { folder: "docs" }];
    expect(describePaste(await readPaste(clipboard(files, "notes.txt")))).toEqual([
      "file notes.txt 5",
      "image image/png shot.png",
      "file docs 0",
    ]);

    // A copied bitmap: the browser names it image.png.
    expect(describePaste(await readPaste(clipboard([new File([png], "image.png", { type: "image/png" })], "")))).toEqual([
      "image image/png null",
    ]);

    // Eleven lines, as Windows copies them.
    const eleven = Array.from({ length: 11 }, (_, index) => `line ${index + 1}`);
    expect(describePaste(await readPaste(clipboard([], eleven.join("\r\n"))))).toEqual([`text ${eleven.join("\n")}`]);
    expect(describePaste(await readPaste(clipboard([], "x".repeat(1001))))).toEqual([`text ${"x".repeat(1001)}`]);

    // Ten lines go in at the cursor, like any other text.
    const ten = Array.from({ length: 10 }, (_, index) => `${index + 1}`).join("\n");
    expect(describePaste(await readPaste(clipboard([], ten)))).toBe(ten);
  });

  test("with a desktop shell's copied paths, of the event's own files only a bitmap counts", async () => {
    const files = [new File(["notes"], "notes.txt"), new File([png], "image.png", { type: "image/png" })];
    expect(describePaste(await readPaste(clipboard(files, "notes.txt"), async () => []))).toEqual(["image image/png null"]);
    expect(describePaste(await readPaste(clipboard([new File(["notes"], "notes.txt")], "notes.txt"), async () => []))).toBe(
      "notes.txt",
    );
  });
});

describe("attachmentsFromPasted", () => {
  test("pasted images become image chips without a name, in order; another file stays a file", async () => {
    const gif = new Uint8Array([0x47, 0x49, 0x46, 0x38, 0x39, 0x61]);
    const cache: Record<string, Blob> = {
      "cache/pasted-1.png": new Blob([png]),
      "cache/pasted-2.gif": new Blob([gif]),
      "cache/pasted-3.pdf": new Blob(["%PDF"]),
    };
    const read = async (url: string) => cache[url] ?? Promise.reject(new Error(`${url}: 404`));
    const attachments = await attachmentsFromPasted(
      [
        { url: "cache/pasted-1.png", name: "pasted-1.png", mimeType: "image/png" },
        { url: "cache/pasted-2.gif", name: "pasted-2.gif", mimeType: "image/gif" },
        { url: "cache/pasted-3.pdf", name: "pasted-3.pdf", mimeType: "application/pdf" },
      ],
      read,
    );
    expect(attachments.map(describeAttachment)).toEqual([
      "image image/png null",
      "image image/gif null",
      "file pasted-3.pdf 4",
    ]);
    expect(attachments[0]).toMatchObject({ image: { data: base64Encode(png) } });
    expect(await attachmentsFromPasted([{ url: "cache/gone.png", name: "gone.png", mimeType: "image/png" }], read).catch(
      (error: unknown) => String(error),
    )).toContain("cache/gone.png");
  });
});
