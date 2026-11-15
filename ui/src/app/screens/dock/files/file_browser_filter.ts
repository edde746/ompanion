// Client-side filter of the Files tab's already-loaded rows. Dot-hides and the name query never ask the machine again.
import type { HostDirEntry } from "../../../../core/transport/host_link";
import type { BrowserRow, EntryRow } from "../../../files/file_workspace";

/** How the Files tab hides and searches the rows {@link FileWorkspace.rows} already holds. */
export interface FileBrowserFilter {
  readonly hideDotFolders: boolean;
  readonly hideDotFiles: boolean;
  /** Case-insensitive substring of the entry name; surrounding spaces do not count. */
  readonly query: string;
}

export function filterBrowserRows(rows: readonly BrowserRow[], filter: FileBrowserFilter): readonly BrowserRow[] {
  const needle = filter.query.trim().toLowerCase();
  const dots = filter.hideDotFolders || filter.hideDotFiles;
  if (!dots && needle === "") return rows;
  const afterDots = dots ? dropHiddenDotTrees(rows, filter) : rows;
  return needle === "" ? afterDots : keepMatchesAndAncestors(afterDots, needle);
}

/** True when a non-empty query left no file, folder, load or error to show. */
export function fileBrowserNoMatches(rows: readonly BrowserRow[], query: string): boolean {
  if (query.trim() === "") return false;
  return !rows.some((row) => row.kind === "EntryRow" || row.kind === "LoadingRow" || row.kind === "FailedRow");
}

export function passesDotFilter(
  entry: HostDirEntry,
  filter: Pick<FileBrowserFilter, "hideDotFolders" | "hideDotFiles">,
): boolean {
  if (!entry.name.startsWith(".")) return true;
  return entry.stat.isDirectory ? !filter.hideDotFolders : !filter.hideDotFiles;
}

function dropHiddenDotTrees(rows: readonly BrowserRow[], filter: FileBrowserFilter): BrowserRow[] {
  const out: BrowserRow[] = [];
  let skipDeeperThan: number | undefined;
  for (const row of rows) {
    if (skipDeeperThan !== undefined) {
      if (row.depth > skipDeeperThan) continue;
      skipDeeperThan = undefined;
    }
    if (row.kind === "EntryRow" && !passesDotFilter(row.entry, filter)) {
      if (row.entry.stat.isDirectory) skipDeeperThan = row.depth;
      continue;
    }
    out.push(row);
  }
  return out;
}

function keepMatchesAndAncestors(rows: readonly BrowserRow[], needle: string): BrowserRow[] {
  const keepEntry = new Set<EntryRow>();
  const keepStatus = new Set<BrowserRow>();
  const ancestors: EntryRow[] = [];
  for (const row of rows) {
    while (ancestors.length > 0) {
      const parent = ancestors[ancestors.length - 1];
      if (parent === undefined || parent.depth < row.depth) break;
      ancestors.pop();
    }
    if (row.kind === "EntryRow") {
      if (row.entry.name.toLowerCase().includes(needle)) {
        keepEntry.add(row);
        for (const ancestor of ancestors) keepEntry.add(ancestor);
      }
      if (row.entry.stat.isDirectory) ancestors.push(row);
      continue;
    }
    if (row.depth === 0) {
      if (row.kind !== "EmptyRow") keepStatus.add(row);
      continue;
    }
    const parent = ancestors[ancestors.length - 1];
    if (parent !== undefined && parent.depth === row.depth - 1 && keepEntry.has(parent)) keepStatus.add(row);
  }
  return rows.filter((row) => (row.kind === "EntryRow" ? keepEntry.has(row) : keepStatus.has(row)));
}
