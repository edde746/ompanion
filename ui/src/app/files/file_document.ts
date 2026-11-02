// Port of lib/files/file_document.dart. The text lives in the file editor's CodeMirror state once an editor showed the
// document (it carries the selection and undo history across remounts), and in a plain string before that. Only the
// state's type is imported here: CodeMirror loads with the editor's chunk, never with the workspace.
import type { EditorState } from "@codemirror/state";
import { type Accessor, createSignal, type Setter } from "solid-js";
import { type HostFiles, type HostFileStat, HostLinkException } from "../../core/transport/host_link";

/** Files larger than this open as a read-only preview of their first bytes. */
export const maxEditableBytes = 2 * 1024 * 1024;

/** Why a document is read-only. */
export type ReadOnlyReason = "tooLarge" | "binary" | "notUtf8";

/** The line breaks a file's lines end with. */
export type LineBreak = "\n" | "\r\n" | "\r";

/** The file changed on the machine since it was loaded or last saved. */
export class FileChangedOnDisk extends Error {
  readonly path: string;
  readonly deleted: boolean;

  constructor(path: string, options: { deleted: boolean }) {
    super(options.deleted ? `${path} was deleted` : `${path} changed on the machine`);
    this.name = "FileChangedOnDisk";
    this.path = path;
    this.deleted = options.deleted;
  }
}

/**
 * One file open in the Files tab: its text, and the size and time it had on disk, which {@link save} compares before
 * writing so an edit made elsewhere is never silently overwritten. Reads track: {@link path}, {@link dirty},
 * {@link saving}, {@link readOnlyReason} and {@link revision} follow the document in a tracking scope.
 */
export class FileDocument {
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private currentPath: string;
  private stat: HostFileStat;
  /** The text as loaded or last saved, lines joined by `\n`. */
  private saved: string;
  /** The text while no editor holds it. */
  private plain: string;
  private state: EditorState | undefined;
  /** The file's line break, written after every line on save. The editor splits lines at every break. */
  private lineBreak: LineBreak;
  private reason: ReadOnlyReason | undefined;
  private isDirty = false;
  private isSaving = false;
  private textRevision = 0;

  /** A line (1-based) the editor should reveal once laid out. */
  pendingLine: number | undefined;

  private constructor(path: string, text: string, stat: HostFileStat, reason: ReadOnlyReason | undefined) {
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
    this.currentPath = path;
    this.stat = stat;
    this.lineBreak = lineBreakOf(text);
    this.plain = this.saved = withLf(text);
    this.reason = reason;
  }

  /** Reads `path` (SFTP space). Throws {@link HostLinkException} when it is missing or a directory. */
  static async load(files: HostFiles, path: string): Promise<FileDocument> {
    const [text, stat, reason] = await read(files, path);
    return new FileDocument(path, text, stat, reason);
  }

  path(): string {
    this.changed();
    return this.currentPath;
  }

  /** Set when the document can be viewed only. */
  readOnlyReason(): ReadOnlyReason | undefined {
    this.changed();
    return this.reason;
  }

  readOnly(): boolean {
    return this.readOnlyReason() !== undefined;
  }

  /** Edited since the last load or save. Undoing back to the saved text makes it clean again. */
  dirty(): boolean {
    this.changed();
    return this.isDirty;
  }

  saving(): boolean {
    this.changed();
    return this.isSaving;
  }

  get baseline(): HostFileStat {
    return this.stat;
  }

  /** Bumps when the text was replaced from outside the editor (a reload), which then starts from {@link text}. */
  revision(): number {
    this.changed();
    return this.textRevision;
  }

  /** The text, lines joined by `\n`. */
  text(): string {
    return this.state === undefined ? this.plain : this.state.doc.toString();
  }

  /** Replaces the text; line breaks of any kind split lines, as the editor does. */
  setText(text: string): void {
    this.plain = withLf(text);
    this.state = undefined;
    this.textRevision++;
    this.isDirty = this.plain !== this.saved;
    this.notify();
  }

  /** The editor's state as the editor last left it; undefined until an editor showed the text, and after a reload. */
  editorState(): EditorState | undefined {
    return this.state;
  }

  /** The editor's state after a transaction. */
  edited(state: EditorState): void {
    const docChanged = this.state?.doc !== state.doc;
    this.state = state;
    if (!docChanged) return;
    const dirty = this.differsFromSaved();
    if (dirty === this.isDirty) return;
    this.isDirty = dirty;
    this.notify();
  }

  /** The file moved (renamed here or a parent directory renamed). */
  movedTo(path: string): void {
    this.currentPath = path;
    this.notify();
  }

  /**
   * Writes the text back. Unless `force`, first checks that size and modification time still match what was loaded,
   * and throws {@link FileChangedOnDisk} when they do not.
   */
  async save(files: HostFiles, options: { force?: boolean } = {}): Promise<void> {
    if (this.reason !== undefined) throw new Error(`${this.currentPath} is read-only`);
    const path = this.currentPath;
    this.isSaving = true;
    this.notify();
    try {
      if (options.force !== true) {
        const current = await files.stat(path);
        if (current === null) throw new FileChangedOnDisk(path, { deleted: true });
        if (current.size !== this.stat.size || current.modifiedMs !== this.stat.modifiedMs) {
          throw new FileChangedOnDisk(path, { deleted: false });
        }
      }
      const text = this.text();
      await files.write(path, new TextEncoder().encode(this.lineBreak === "\n" ? text : text.replaceAll("\n", this.lineBreak)));
      this.saved = text;
      this.stat = (await files.stat(path)) ?? this.stat;
      this.isDirty = this.differsFromSaved();
    } finally {
      this.isSaving = false;
      this.notify();
    }
  }

  /** Replaces the text with the file's current content, dropping edits. */
  async reload(files: HostFiles): Promise<void> {
    const [text, stat, reason] = await read(files, this.currentPath);
    this.plain = this.saved = withLf(text);
    this.state = undefined;
    this.textRevision++;
    this.stat = stat;
    this.lineBreak = lineBreakOf(text);
    this.reason = reason;
    this.isDirty = false;
    this.notify();
  }

  /** Compares lengths first: an edit that changes the length needs no look at the text. */
  private differsFromSaved(): boolean {
    const doc = this.state?.doc;
    if (doc === undefined) return this.plain !== this.saved;
    return doc.length !== this.saved.length || doc.toString() !== this.saved;
  }

  private notify(): void {
    this.setChanged((count) => count + 1);
  }
}

async function read(files: HostFiles, path: string): Promise<[string, HostFileStat, ReadOnlyReason | undefined]> {
  const stat = await files.stat(path);
  if (stat === null) throw new HostLinkException(`no such file: ${path}`);
  if (stat.isDirectory) throw new HostLinkException(`${path} is a directory`);
  // Always a bounded read: devices and /proc files report size 0 yet never end, or hold more than they report.
  const bytes = await files.read(path, { length: maxEditableBytes + 1 });
  const tooLarge = bytes.length > maxEditableBytes;
  const [text, reason] = decodeFileText(tooLarge ? bytes.subarray(0, maxEditableBytes) : bytes, { truncated: tooLarge });
  return [text, stat, reason];
}

/**
 * The text of a file's bytes, and why it must stay read-only: `truncated` (only a prefix was read), a NUL byte in the
 * first 8 KiB (binary), or bytes that are not UTF-8 (saving would corrupt them). A byte order mark stays in the text,
 * so saving writes it back.
 */
export function decodeFileText(
  bytes: Uint8Array,
  options: { truncated: boolean },
): [string, ReadOnlyReason | undefined] {
  if (bytes.subarray(0, 8192).includes(0)) return ["", "binary"];
  const lenient = new TextDecoder("utf-8", { ignoreBOM: true });
  if (options.truncated) return [lenient.decode(bytes), "tooLarge"];
  try {
    return [new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes), undefined];
  } catch (error) {
    if (!(error instanceof TypeError)) throw error;
    return [lenient.decode(bytes), "notUtf8"];
  }
}

/** `text` as the editor holds it: `\r\n`, `\r` and `\n` each end a line, and its lines are joined by `\n`. */
function withLf(text: string): string {
  return text.replace(/\r\n?/g, "\n");
}

/** The line break most of `text`'s lines end with, so saving rewrites only the lines that differ from it. */
export function lineBreakOf(text: string): LineBreak {
  let crlf = 0;
  let cr = 0;
  let lf = 0;
  for (let i = 0; i < text.length; i++) {
    const unit = text.charCodeAt(i);
    if (unit === 0x0d && text.charCodeAt(i + 1) === 0x0a) {
      crlf++;
      i++;
    } else if (unit === 0x0d) {
      cr++;
    } else if (unit === 0x0a) {
      lf++;
    }
  }
  if (crlf > lf && crlf >= cr) return "\r\n";
  if (cr > lf && cr > crlf) return "\r";
  return "\n";
}
