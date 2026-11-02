// Port of lib/screens/chat/attachment_input.dart. A desktop shell with `paths` (shell.info) names files and folders by
// their paths on this computer: picked (`shell.pickFiles`), dropped (`shell.drop`) or copied in the file manager
// (`shell.clipboardFiles`). Elsewhere the page reads pastes and drops itself, a paste event's clipboard data (or
// `navigator.clipboard.read()` where a paste event carries nothing the page can read) and a drop's data transfer, and
// files arrive as their bytes. iOS's menu Paste and an Android keyboard's images come from the shell
// (`shell.pasteFiles`).
import { toSftpPath } from "../../../core/host/scripts";
import type { RpcImage } from "../../../core/rpc/results";
import { BridgeLink } from "../../../core/transport/bridge_link";
import { base64Encode } from "../../../core/util/base64";
import { baseName } from "../../files/file_paths";
import type { PastedFile } from "../../platform";
import {
  type ComposerAttachment,
  fileAttachment,
  folderAttachment,
  type ImageAttachment,
  imageAttachment,
  pathAttachment,
  textAttachment,
} from "../../sessions/composer_attachments";

/** What a paste puts into the composer: chips (copied files, an image, a large text), or text typed in at the cursor. */
export type Paste =
  | { readonly kind: "PasteAttachments"; readonly attachments: readonly ComposerAttachment[] }
  | { readonly kind: "PasteText"; readonly text: string };

/**
 * Whether the TUI collapses a paste of `text` into a chip: over 10 lines or 1000 characters (its editor's
 * "marker-sized" paste).
 */
export function isLargePaste(text: string): boolean {
  let lines = 1;
  for (const character of text) if (character === "\n") lines++;
  return lines > 10 || text.length > 1000;
}

/** Image types omp takes as image content, by file extension. */
const imageTypes: Readonly<Record<string, string>> = {
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
};

/** The image type of a file named `name`, of those omp takes as image content, or undefined. */
export function imageTypeOfName(name: string): string | undefined {
  const dot = name.lastIndexOf(".");
  return dot < 0 ? undefined : imageTypes[name.substring(dot).toLowerCase()];
}

/** The image type `bytes` start with, of those omp takes as image content, or undefined. */
export function imageMimeType(bytes: Uint8Array): string | undefined {
  const at = (offset: number, magic: readonly number[]) =>
    bytes.length >= offset + magic.length && magic.every((byte, index) => bytes[offset + index] === byte);
  if (at(0, [0x89, 0x50, 0x4e, 0x47])) return "image/png";
  if (at(0, [0xff, 0xd8, 0xff])) return "image/jpeg";
  if (at(0, [0x47, 0x49, 0x46, 0x38])) return "image/gif";
  if (at(0, [0x52, 0x49, 0x46, 0x46]) && at(8, [0x57, 0x45, 0x42, 0x50])) return "image/webp";
  return undefined;
}

/** A copied image as an attachment; omp takes PNG, JPEG, GIF and WebP as image content. */
export function pastedImage(bytes: Uint8Array): ImageAttachment {
  const mimeType = imageMimeType(bytes);
  if (mimeType === undefined) throw new Error("The clipboard image is not PNG, JPEG, GIF or WebP.");
  const image: RpcImage = { data: base64Encode(bytes), mimeType };
  return imageAttachment(image);
}

/**
 * The attachment for a file of this device, as a drop, a paste or the file picker brings it: an image omp takes as
 * image content becomes an ImageAttachment, as the TUI sends a pasted image; any other file a FileAttachment the
 * prompt mentions. A pasted bitmap (a file of an image type the browser names `image.png`) keeps no name.
 */
export async function attachmentFromFile(file: File): Promise<ComposerAttachment> {
  const mimeType = imageTypeOfFile(file);
  if (mimeType === undefined) return fileAttachment(file.name, file);
  const image = { data: base64Encode(new Uint8Array(await file.arrayBuffer())), mimeType };
  return file.name === "image.png" || file.name === "" ? imageAttachment(image) : imageAttachment(image, file.name);
}

/** The image type of `file` by its name or the type the browser gives it, of those omp takes as image content. */
function imageTypeOfFile(file: File): string | undefined {
  return imageTypeOfName(file.name) ?? Object.values(imageTypes).find((type) => type === file.type);
}

/** A file or folder a drop or a paste carries. */
type Carried = File | { readonly folder: string };

/**
 * The files and folders `transfer` carries, in order; entries that are no file, such as a link dragged from a browser,
 * are left out. Synchronous: a data transfer is emptied once its event returns.
 */
export function carriedFiles(transfer: DataTransfer): readonly Carried[] {
  const carried: Carried[] = [];
  for (const item of Array.from(transfer.items)) {
    if (item.kind !== "file") continue;
    const entry = item.webkitGetAsEntry();
    if (entry?.isDirectory) {
      carried.push({ folder: entry.name });
      continue;
    }
    const file = item.getAsFile();
    if (file !== null) carried.push(file);
  }
  return carried;
}

/** Attachments for what carriedFiles found, in order. */
export async function attachmentsFrom(carried: readonly Carried[]): Promise<ComposerAttachment[]> {
  const attachments: ComposerAttachment[] = [];
  for (const item of carried) {
    attachments.push(item instanceof File ? await attachmentFromFile(item) : folderAttachment(item.folder));
  }
  return attachments;
}

/**
 * Attachments for files and folders on this computer, as a desktop shell names them (dropped, picked, copied): an
 * image omp takes as image content becomes an ImageAttachment, any other file and a folder a FileAttachment the
 * prompt mentions. Paths that name nothing on disk, or no file or folder (a socket, a pipe), are left out.
 */
export async function attachmentsFromPaths(paths: readonly string[]): Promise<ComposerAttachment[]> {
  if (paths.length === 0) return [];
  const device = new BridgeLink("local");
  try {
    const files = await device.files();
    const attachments: ComposerAttachment[] = [];
    for (const path of paths) {
      const at = toSftpPath(path);
      const name = baseName(at);
      const stat = await files.stat(at);
      if (stat === null) continue;
      if (stat.isDirectory) {
        attachments.push(folderAttachment(name, path));
        continue;
      }
      // A regular file by its mode's file type bits.
      if (stat.mode === undefined || (stat.mode & 0o170000) !== 0o100000) continue;
      const mimeType = imageTypeOfName(name);
      attachments.push(
        mimeType === undefined
          ? pathAttachment(name, stat.size, path)
          : imageAttachment({ data: base64Encode(await files.read(at)), mimeType }, name),
      );
    }
    return attachments;
  } finally {
    await device.close();
  }
}

/**
 * Attachments for files the shell pasted into its cache (`shell.pasteFiles`), fetched with `read`: an image omp takes
 * as image content keeps no name, as a pasted bitmap; any other file is a file of this device.
 */
export async function attachmentsFromPasted(
  pasted: readonly PastedFile[],
  read: (url: string) => Promise<Blob> = fetchBlob,
): Promise<ComposerAttachment[]> {
  const attachments: ComposerAttachment[] = [];
  for (const file of pasted) {
    const blob = await read(file.url);
    attachments.push(
      Object.values(imageTypes).includes(file.mimeType)
        ? imageAttachment({ data: base64Encode(new Uint8Array(await blob.arrayBuffer())), mimeType: file.mimeType })
        : fileAttachment(file.name, blob),
    );
  }
  return attachments;
}

async function fetchBlob(url: string): Promise<Blob> {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${url}: ${response.status} ${response.statusText}`);
  return response.blob();
}

/**
 * Reads a paste in the order the TUI and chat apps take the clipboard: copied files, then a bitmap, then text. Text
 * over 10 lines or 1000 characters becomes a chip (isLargePaste); undefined when there is nothing to paste. Reads the
 * event's `data` before its first await. With `copiedPaths` (a desktop shell's `shell.clipboardFiles`) the copied
 * files are those paths, and of the event's files only a bitmap counts. A paste event without anything the page can
 * read falls back to `navigator.clipboard.read()` where the webview has it.
 */
export async function readPaste(
  data: DataTransfer | null,
  copiedPaths?: () => Promise<readonly string[]>,
): Promise<Paste | undefined> {
  const carried = data === null ? [] : carriedFiles(data);
  const text = data?.getData("text/plain") ?? "";
  if (copiedPaths !== undefined) {
    const copied = await attachmentsFromPaths(await copiedPaths());
    if (copied.length > 0) return { kind: "PasteAttachments", attachments: copied };
    const bitmap = carried.find((item) => item instanceof File && imageTypeOfFile(item) !== undefined);
    if (bitmap instanceof File) return { kind: "PasteAttachments", attachments: [await attachmentFromFile(bitmap)] };
  } else if (carried.length > 0) {
    return { kind: "PasteAttachments", attachments: await attachmentsFrom(carried) };
  }
  if (text.length > 0) return pasteOfText(text);
  return readClipboard();
}

function pasteOfText(raw: string): Paste {
  const text = raw.replace(/\r\n?/g, "\n");
  return isLargePaste(text)
    ? { kind: "PasteAttachments", attachments: [textAttachment(text)] }
    : { kind: "PasteText", text };
}

/** `navigator.clipboard.read()`, where the webview offers it: a bitmap first, then text. */
async function readClipboard(): Promise<Paste | undefined> {
  if (navigator.clipboard?.read === undefined) return undefined;
  const items = await navigator.clipboard.read();
  for (const item of items) {
    const type = item.types.find((candidate) => candidate.startsWith("image/"));
    if (type === undefined) continue;
    const bytes = new Uint8Array(await (await item.getType(type)).arrayBuffer());
    return { kind: "PasteAttachments", attachments: [pastedImage(bytes)] };
  }
  for (const item of items) {
    if (!item.types.includes("text/plain")) continue;
    const text = await (await item.getType("text/plain")).text();
    if (text.length > 0) return pasteOfText(text);
  }
  return undefined;
}
