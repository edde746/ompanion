// Scope the file preview hands the markdown renderer: resolved wikilinks and in-page heading jumps.
import { type Accessor, createContext } from "solid-js";
import { normalizePath } from "../app/files/file_paths";

export interface FilePreviewScopeValue {
  /** The open markdown file's path; a `[[Note#Heading]]` to this file scrolls here instead of remounting. */
  readonly path: string;
  /** Wikilink destination as written → absolute SFTP path, or undefined when the target is missing. */
  readonly resolved: ReadonlyMap<string, string | undefined>;
  readonly scrollToHeading: (id: string) => void;
}

export const FilePreviewScope = createContext<Accessor<FilePreviewScopeValue> | null>(null);

const pendingHeadings = new Map<string, string>();

/** Remember a `[[Note#Heading]]` jump until that file's preview mounts. */
export function requestPreviewHeading(path: string, heading: string): void {
  pendingHeadings.set(normalizePath(path), heading);
}

export function takePreviewHeading(path: string): string | undefined {
  const key = normalizePath(path);
  const heading = pendingHeadings.get(key);
  pendingHeadings.delete(key);
  return heading;
}
