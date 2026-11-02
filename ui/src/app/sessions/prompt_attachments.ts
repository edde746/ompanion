// Port of lib/sessions/prompt_attachments.dart.
import { hostPath, toSftpPath } from "../../core/host/scripts";
import { savePaste, uploadAttachment } from "../../core/host/upload";
import { asJsonObject, string } from "../../core/rpc/json_fields";
import type { RpcImage } from "../../core/rpc/results";
import type { LiveSession } from "../../core/session/live_session";
import { BridgeLink } from "../../core/transport/bridge_link";
import type { HostFiles, HostLink } from "../../core/transport/host_link";
import type { Translations } from "../i18n/i18n";
import { formatBytes } from "../utils/byte_size";
import type { ComposerAttachment, FileAttachment } from "./composer_attachments";

/**
 * What omp receives for a composed prompt: `message` with every attachment turned into text omp understands (expanded
 * paste, `@` mention of an uploaded file), and the images to send as image content.
 */
export interface PreparedPrompt {
  readonly message: string;
  readonly images: readonly RpcImage[];
}

/**
 * The largest file a prompt takes. omp auto-reads text up to 5 MB and images up to 25 MB and names a larger file by
 * its path only, so beyond this the upload costs more than the model gains.
 */
export const maxAttachmentBytes = 100 << 20;

/**
 * A paste above this many UTF-8 bytes goes to the session's `local://` store as `paste-<n>.md`, which the message
 * names, as the TUI's "Attach as local file" does: inline it would take a large share of the model's context.
 */
export const pasteFileThreshold = 256 << 10;

/** Bytes read from a file per upload part: the upload writes 4 MiB at a time, so reading ahead of it gains nothing. */
const readChunk = 4 << 20;

/**
 * Turns `attachments` into what omp receives with `text` (the composer's trimmed text):
 * - an ImageAttachment is image content; omp resizes it as it resizes a mentioned image;
 * - a TextAttachment is its text, or `local://paste-<n>.md` above pasteFileThreshold;
 * - a FileAttachment is an `@` mention of the file's path on the session's machine, which omp auto-reads. On this
 *   computer a file or folder with a path is mentioned where it is; any other file is uploaded into the session's
 *   `local://` directory (companion verb `session.localRoot`), whose lifecycle is omp's: deleting the session deletes
 *   it.
 *
 * `link` opens the session's machine; it is called only when a file or a large paste needs the machine.
 * `onUploadProgress` reports the bytes written to the machine so far and in all. Throws AttachmentException.
 */
export async function preparePrompt(options: PrepareOptions): Promise<PreparedPrompt> {
  // This device's files, where an attachment's path is; reached only when an attachment has one.
  const device = options.attachments.some((attachment) => attachment.kind === "FileAttachment" && attachment.path)
    ? new BridgeLink("local")
    : undefined;
  try {
    return await prepare(options, await device?.files());
  } finally {
    await device?.close();
  }
}

interface PrepareOptions {
  readonly text: string;
  readonly attachments: readonly ComposerAttachment[];
  readonly session: LiveSession;
  readonly link: () => Promise<HostLink>;
  readonly onUploadProgress?: (sent: number, total: number) => void;
}

async function prepare(options: PrepareOptions, device: HostFiles | undefined): Promise<PreparedPrompt> {
  const { text, attachments, session } = options;
  const images = attachments.flatMap((attachment) => (attachment.kind === "ImageAttachment" ? [attachment.image] : []));
  const encoder = new TextEncoder();
  const sizes = new Map<ComposerAttachment, number>();
  const bigPastes = new Set<ComposerAttachment>();
  const files: FileAttachment[] = [];
  for (const attachment of attachments) {
    if (attachment.kind === "FileAttachment") {
      sizes.set(attachment, await sizeOf(attachment, device));
      files.push(attachment);
    } else if (attachment.kind === "TextAttachment") {
      const size = encoder.encode(attachment.text).length;
      sizes.set(attachment, size);
      if (size > pasteFileThreshold) bigPastes.add(attachment);
    }
  }

  // Undefined until a file or a large paste needs the machine.
  let host: HostLink | undefined;
  if (files.length > 0 || bigPastes.size > 0) {
    try {
      host = await options.link();
    } catch (error) {
      throw new AttachmentUploadFailed(files[0]?.name, error);
    }
  }
  const local = host instanceof BridgeLink && host.machine === "local";
  const uploads = attachments.filter(
    (attachment) =>
      (attachment.kind === "FileAttachment" && !(local && mentionableInPlace(attachment))) || bigPastes.has(attachment),
  );
  for (const upload of uploads) {
    if (upload.kind === "FileAttachment" && sizes.get(upload)! < 0) throw new AttachmentIsFolder(upload.name);
  }

  // Where each upload landed: a host-native path for a file, a `local://` name for a paste.
  const written = new Map<ComposerAttachment, string>();
  if (uploads.length > 0) {
    const nameOf = (upload: ComposerAttachment) => (upload.kind === "FileAttachment" ? upload.name : undefined);
    const first = uploads[0]!;
    if (session.companionHello === undefined) throw new AttachmentNeedsCompanion(nameOf(first));
    let root: string;
    let machineFiles: HostFiles;
    try {
      const reply = await session.companion.call("session.localRoot");
      root = toSftpPath(string(asJsonObject(reply, "session.localRoot"), "path"));
      machineFiles = await host!.files();
    } catch (error) {
      throw new AttachmentUploadFailed(nameOf(first), error);
    }
    try {
      const total = uploads.reduce((sum, upload) => sum + sizes.get(upload)!, 0);
      let done = 0;
      const progress = (sent: number) => options.onUploadProgress?.(done + sent, total);
      progress(0);
      for (const upload of uploads) {
        try {
          if (upload.kind === "FileAttachment") {
            const target = await uploadAttachment(machineFiles, {
              dir: root,
              name: upload.name,
              bytes: upload.path === undefined ? chunksOf(upload.file!) : chunksAt(device!, toSftpPath(upload.path)),
              onProgress: progress,
            });
            written.set(upload, hostPath(target));
          } else if (upload.kind === "TextAttachment") {
            const name = await savePaste(machineFiles, { dir: root, text: upload.text, onProgress: progress });
            written.set(upload, `local://${name}`);
          }
        } catch (error) {
          throw new AttachmentUploadFailed(nameOf(upload), error);
        }
        done += sizes.get(upload)!;
      }
    } finally {
      await machineFiles.close();
    }
  }

  const parts: string[] = [];
  for (const attachment of attachments) {
    if (attachment.kind === "TextAttachment") parts.push(written.get(attachment) ?? attachment.text);
    if (attachment.kind !== "FileAttachment") continue;
    const path = written.get(attachment) ?? attachment.path!;
    const mentioned = fileMention(path);
    if (mentioned === undefined) {
      throw new AttachmentUploadFailed(attachment.name, `no @ mention can carry the path ${path}`);
    }
    parts.push(mentioned);
  }
  return { message: assembleMessage(text, parts), images };
}

/** The file's size now, -1 for a folder. Throws AttachmentMissing and AttachmentTooLarge. */
async function sizeOf(file: FileAttachment, device: HostFiles | undefined): Promise<number> {
  if (file.path === undefined) {
    // A folder dropped or pasted in the page, which has neither its path nor its bytes.
    if (file.file === undefined) return -1;
    if (file.size > maxAttachmentBytes) throw new AttachmentTooLarge(file.name, file.size);
    return file.size;
  }
  const stat = await device!.stat(toSftpPath(file.path));
  if (stat === null) throw new AttachmentMissing(file.name);
  if (stat.isDirectory) return -1;
  if (stat.size > maxAttachmentBytes) throw new AttachmentTooLarge(file.name, stat.size);
  return stat.size;
}

/** A file or folder on this computer that omp, running here too, reads where it is. */
function mentionableInPlace(file: FileAttachment): boolean {
  return file.path !== undefined && fileMention(file.path) !== undefined;
}

/** The file's bytes one part at a time, read as the upload takes them. */
async function* chunksOf(file: Blob): AsyncGenerator<Uint8Array> {
  for (let offset = 0; offset < file.size; offset += readChunk) {
    yield new Uint8Array(await file.slice(offset, offset + readChunk).arrayBuffer());
  }
}

/** The bytes of the file at `path` on this device, read one part at a time as the upload takes them. */
async function* chunksAt(device: HostFiles, path: string): AsyncGenerator<Uint8Array> {
  for (let offset = 0; ; offset += readChunk) {
    const chunk = await device.read(path, { offset, length: readChunk });
    if (chunk.length > 0) yield chunk;
    if (chunk.length < readChunk) return;
  }
}

/**
 * `text` with `parts` appended as the TUI expands chips inserted at the end of the typed text: after a space unless
 * the text ends in whitespace, one space between parts (the space the TUI puts after a chip), and the whole message
 * trimmed as the TUI trims it on submit.
 */
export function assembleMessage(text: string, parts: readonly string[]): string {
  if (parts.length === 0) return text.trim();
  const separator = text.length === 0 || text.trimEnd().length !== text.length ? "" : " ";
  return `${text}${separator}${parts.join(" ")}`.trim();
}

/**
 * An `@` mention omp resolves to `path` (host-native; file-mentions.ts `FILE_MENTION_REGEX`): `@"path"`, or `@'path'`
 * when the path has a double quote. Undefined when it has both quotes or starts or ends with whitespace, which no
 * quoted mention keeps.
 */
export function fileMention(path: string): string | undefined {
  if (path.length === 0 || path.trim().length !== path.length) return undefined;
  if (!path.includes('"')) return `@"${path}"`;
  if (!path.includes("'")) return `@'${path}'`;
  return undefined;
}

/** Why a prompt with attachments was not sent. `attachment` is the file's name; undefined for a paste. */
export abstract class AttachmentException extends Error {
  constructor(readonly attachment: string | undefined) {
    super();
  }

  /** The user-facing message. */
  abstract describe(t: Translations): string;

  protected label(t: Translations): string {
    return this.attachment ?? t.attachments.paste;
  }
}

/** A file above maxAttachmentBytes. */
export class AttachmentTooLarge extends AttachmentException {
  override name = "AttachmentTooLarge";

  constructor(
    attachment: string,
    readonly size: number,
  ) {
    super(attachment);
    this.message = `${attachment} is ${size} bytes`;
  }

  describe(t: Translations): string {
    return t.attachments.tooLarge({
      name: this.label(t),
      size: formatBytes(this.size),
      limit: formatBytes(maxAttachmentBytes),
    });
  }
}

/** A file with a path is no longer on this device. */
export class AttachmentMissing extends AttachmentException {
  override name = "AttachmentMissing";

  constructor(attachment: string) {
    super(attachment);
    this.message = `${attachment} is missing`;
  }

  describe(t: Translations): string {
    return t.attachments.missing({ name: this.label(t) });
  }
}

/** A folder attached to a session on another machine; folders are only mentioned where they are. */
export class AttachmentIsFolder extends AttachmentException {
  override name = "AttachmentIsFolder";

  constructor(attachment: string) {
    super(attachment);
    this.message = `${attachment} is a folder`;
  }

  describe(t: Translations): string {
    return t.attachments.folder({ name: this.label(t) });
  }
}

/** The session has no companion to name its `local://` directory. */
export class AttachmentNeedsCompanion extends AttachmentException {
  override name = "AttachmentNeedsCompanion";

  constructor(attachment: string | undefined) {
    super(attachment);
    this.message = "the session has no companion";
  }

  describe(t: Translations): string {
    return t.attachments.needsCompanion({ name: this.label(t) });
  }
}

/** Reaching the machine, the companion or the file failed while copying `attachment` to the machine. */
export class AttachmentUploadFailed extends AttachmentException {
  override name = "AttachmentUploadFailed";

  constructor(
    attachment: string | undefined,
    override readonly cause: unknown,
  ) {
    super(attachment);
    this.message = String(cause);
  }

  describe(t: Translations): string {
    return t.attachments.uploadFailed({ name: this.label(t), error: String(this.cause) });
  }
}
