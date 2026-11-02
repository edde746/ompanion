// Port of the cases of test/sessions/prompt_attachments_test.dart with files and folders that have a path on this
// computer: a desktop shell names them so (shell.info `paths`), and the core reads them (`fs.*` on machine `local`).
import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import type { RpcImage } from "../../core/rpc/results";
import type { HostLink } from "../../core/transport/host_link";
import { localLink, useCore } from "../../test/core";
import { FakeLiveSession } from "../../test/live_session";
import {
  type ComposerAttachment,
  folderAttachment,
  imageAttachment,
  pathAttachment,
  textAttachment,
} from "./composer_attachments";
import {
  AttachmentIsFolder,
  AttachmentMissing,
  AttachmentTooLarge,
  maxAttachmentBytes,
  preparePrompt,
} from "./prompt_attachments";

useCore();

const image: RpcImage = { data: "iVBORw0KGgo=", mimeType: "image/png" };

/** Another machine, as far as preparePrompt can tell. */
const elsewhere = {} as HostLink;

let temp: string;
let links: number;

beforeEach(async () => {
  temp = await fs.mkdtemp(path.join(os.tmpdir(), "prompt-attachments-"));
  links = 0;
});

afterEach(() => fs.rm(temp, { recursive: true, force: true }));

/** A session whose process has no companion: anything that needs the machine's `local://` directory fails. */
function prepare(text: string, attachments: ComposerAttachment[], link?: HostLink) {
  return preparePrompt({
    text,
    attachments,
    session: new FakeLiveSession(),
    link: async () => {
      links++;
      return link ?? localLink();
    },
  });
}

describe("preparePrompt", () => {
  test("mentions files and folders of this computer where they are, in attachment order", async () => {
    const file = path.join(temp, "build log.txt");
    await fs.writeFile(file, "log");
    const folder = path.join(temp, "src");
    await fs.mkdir(folder);
    const prepared = await prepare("why", [
      pathAttachment("build log.txt", 3, file),
      textAttachment("pasted"),
      imageAttachment(image),
      folderAttachment("src", folder),
    ]);
    expect(prepared.message).toBe(`why @"${file}" pasted @"${folder}"`);
    expect(prepared.images).toEqual([image]);
  });

  test("a file that left this device fails before anything is sent", async () => {
    const failure = await prepare("x", [pathAttachment("gone.txt", 1, path.join(temp, "gone.txt"))]).catch(
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(AttachmentMissing);
    expect((failure as AttachmentMissing).attachment).toBe("gone.txt");
    expect(links).toBe(0);
  });

  test("a file above the limit is refused by its size on disk now", async () => {
    const big = path.join(temp, "big.bin");
    await fs.writeFile(big, "");
    await fs.truncate(big, maxAttachmentBytes + 1);
    const failure = await prepare("x", [pathAttachment("big.bin", 1, big)]).catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(AttachmentTooLarge);
    expect((failure as AttachmentTooLarge).size).toBe(maxAttachmentBytes + 1);
  });

  test("a folder cannot go to another machine", async () => {
    const failure = await prepare("x", [folderAttachment("src", temp)], elsewhere).catch((error: unknown) => error);
    expect(failure).toBeInstanceOf(AttachmentIsFolder);
  });
});
