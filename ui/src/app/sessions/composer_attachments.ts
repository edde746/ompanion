// Port of lib/sessions/composer_attachments.dart.
import type { RpcImage } from "../../core/rpc/results";

/**
 * Something attached to a prompt in the composer: pasted, dropped or picked. Plain data; turning it into what omp
 * receives (upload, `@` mention, inline text) happens when the prompt is sent.
 */
export type ComposerAttachment = ImageAttachment | FileAttachment | TextAttachment;

/** An image sent with the prompt as image content, as the TUI sends a pasted image. */
export interface ImageAttachment {
  readonly kind: "ImageAttachment";
  readonly image: RpcImage;
  /** The file name when the image came from a file; undefined for a pasted bitmap. */
  readonly name?: string;
}

/**
 * A file or folder from this device. It goes to the session's machine and the prompt mentions it, so omp reads it the
 * way it reads an `@path` typed in the TUI. A desktop shell names it by its `path` here (shell.info `paths`); in the
 * page's own pick, drop or paste it arrives as its bytes (`file`), and a dropped folder there has neither.
 */
export interface FileAttachment {
  readonly kind: "FileAttachment";
  readonly name: string;
  /** 0 for a folder, which has no size of its own. */
  readonly size: number;
  readonly folder?: boolean;
  readonly file?: Blob;
  /** Where it is on this device, as the shell names it (host-native). */
  readonly path?: string;
}

/**
 * A large paste kept out of the text field, as the TUI collapses it into a text-attachment chip; its text goes into
 * the message when the prompt is sent.
 */
export interface TextAttachment {
  readonly kind: "TextAttachment";
  readonly text: string;
}

export function imageAttachment(image: RpcImage, name?: string): ImageAttachment {
  return name === undefined ? { kind: "ImageAttachment", image } : { kind: "ImageAttachment", image, name };
}

export function fileAttachment(name: string, file: Blob): FileAttachment {
  return { kind: "FileAttachment", name, size: file.size, file };
}

/** A folder: dropped or pasted in the page, which cannot read it, or named by its `path` (shell.info `paths`). */
export function folderAttachment(name: string, path?: string): FileAttachment {
  return { kind: "FileAttachment", name, size: 0, folder: true, path };
}

export function pathAttachment(name: string, size: number, path: string): FileAttachment {
  return { kind: "FileAttachment", name, size, path };
}

export function textAttachment(text: string): TextAttachment {
  return { kind: "TextAttachment", text };
}

export function textAttachmentLineCount(attachment: TextAttachment): number {
  let lines = 1;
  for (const character of attachment.text) if (character === "\n") lines++;
  return lines;
}
