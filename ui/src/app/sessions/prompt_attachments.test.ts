// Port of test/sessions/prompt_attachments_test.dart, the cases of files the page holds as bytes. The cases of files
// and folders with a path on this computer read them through the core: prompt_attachments.e2e.test.ts.
import { beforeEach, describe, expect, test } from "bun:test";
import type { RpcImage } from "../../core/rpc/results";
import type { HostLink } from "../../core/transport/host_link";
import { FakeLiveSession } from "../../test/live_session";
import {
  type ComposerAttachment,
  fileAttachment,
  folderAttachment,
  imageAttachment,
  textAttachment,
} from "./composer_attachments";
import {
  AttachmentIsFolder,
  AttachmentNeedsCompanion,
  AttachmentTooLarge,
  assembleMessage,
  fileMention,
  maxAttachmentBytes,
  pasteFileThreshold,
  preparePrompt,
} from "./prompt_attachments";

const image: RpcImage = { data: "iVBORw0KGgo=", mimeType: "image/png" };

/** Another machine, as far as preparePrompt can tell: it fails the test when used. */
const elsewhere = {} as HostLink;

let links = 0;

beforeEach(() => {
  links = 0;
});

/** A session whose process has no companion: anything that needs the machine's `local://` directory fails. */
function prepare(text: string, attachments: ComposerAttachment[]) {
  return preparePrompt({
    text,
    attachments,
    session: new FakeLiveSession(),
    link: async () => {
      links++;
      return elsewhere;
    },
  });
}

describe("assembleMessage", () => {
  test("appends each part after the typed text as the TUI expands a chip typed at the end", () => {
    expect(assembleMessage("explain", ["one\ntwo", '@"/a b.txt"'])).toBe('explain one\ntwo @"/a b.txt"');
    expect(assembleMessage("explain:\n", ["body"])).toBe("explain:\nbody");
    expect(assembleMessage("", ["  body\n", "x"])).toBe("body\n x");
    expect(assembleMessage("  just text  ", [])).toBe("just text");
  });
});

describe("fileMention", () => {
  test("quotes the path in the form file-mentions.ts reads back whole", () => {
    expect(fileMention("/home/me/a b@2x.png")).toBe('@"/home/me/a b@2x.png"');
    expect(fileMention('C:\\Users\\me\\say "hi".txt')).toBe(`@'C:\\Users\\me\\say "hi".txt'`);
    expect(fileMention(`/tmp/it's "both"`)).toBeUndefined();
    expect(fileMention("/tmp/trailing ")).toBeUndefined();
  });
});

describe("preparePrompt", () => {
  test("keeps images as image content and small pastes in the message, without touching the machine", async () => {
    const prepared = await prepare("look", [imageAttachment(image), textAttachment("a\nb")]);
    expect(prepared.message).toBe("look a\nb");
    expect(prepared.images).toEqual([image]);
    expect(links).toBe(0);
  });

  test("a file above the limit is refused by its size before anything is sent", async () => {
    const big = { kind: "FileAttachment", name: "big.bin", size: maxAttachmentBytes + 1, file: new Blob([]) } as const;
    const failure = await prepare("x", [big]).catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(AttachmentTooLarge);
    expect((failure as AttachmentTooLarge).size).toBe(maxAttachmentBytes + 1);
    expect(links).toBe(0);
  });

  test("a dropped folder cannot go to a machine", async () => {
    expect(await prepare("x", [folderAttachment("src")]).catch((error: unknown) => error)).toBeInstanceOf(
      AttachmentIsFolder,
    );
  });

  test("an upload or a large paste without the companion fails, naming what needed it", async () => {
    const file = await prepare("x", [fileAttachment("shot.bin", new Blob([new Uint8Array(4)]))]).catch(
      (error: unknown) => error,
    );
    expect(file).toBeInstanceOf(AttachmentNeedsCompanion);
    expect((file as AttachmentNeedsCompanion).attachment).toBe("shot.bin");
    const paste = await prepare("x", [textAttachment("x".repeat(pasteFileThreshold + 1))]).catch(
      (error: unknown) => error,
    );
    expect(paste).toBeInstanceOf(AttachmentNeedsCompanion);
    expect((paste as AttachmentNeedsCompanion).attachment).toBeUndefined();
  });
});
