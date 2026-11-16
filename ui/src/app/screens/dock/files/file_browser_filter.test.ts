import { describe, expect, test } from "bun:test";
import type { HostDirEntry } from "../../../../core/transport/host_link";
import type { BrowserRow, EntryRow } from "../../../files/file_workspace";
import { fileBrowserNoMatches, filterBrowserRows, type FileBrowserFilter } from "./file_browser_filter";

const off: FileBrowserFilter = { hideDotFolders: false, hideDotFiles: false, query: "" };

function file(name: string): HostDirEntry {
  return { name, stat: { size: 4, isDirectory: false, isLink: false } };
}

function dir(name: string): HostDirEntry {
  return { name, stat: { size: 0, isDirectory: true, isLink: false } };
}

function link(name: string): HostDirEntry {
  return { name, stat: { size: 0, isDirectory: false, isLink: true } };
}

function entry(path: string, item: HostDirEntry, depth: number, expanded = false): EntryRow {
  return { kind: "EntryRow", depth, path, entry: item, expanded };
}

function names(rows: readonly BrowserRow[]): string[] {
  return rows.flatMap((row) => (row.kind === "EntryRow" ? [row.entry.name] : [`<${row.kind}>`]));
}

/** A tree: src/{foo.ts, lib/{bar.ts, util.ts}}, .git/{config, HEAD}, .gitignore, README.md. */
function tree(): BrowserRow[] {
  return [
    entry("/w/src", dir("src"), 0, true),
    entry("/w/src/foo.ts", file("foo.ts"), 1),
    entry("/w/src/lib", dir("lib"), 1, true),
    entry("/w/src/lib/bar.ts", file("bar.ts"), 2),
    entry("/w/src/lib/util.ts", file("util.ts"), 2),
    entry("/w/.git", dir(".git"), 0, true),
    entry("/w/.git/config", file("config"), 1),
    entry("/w/.git/HEAD", file("HEAD"), 1),
    entry("/w/.gitignore", file(".gitignore"), 0),
    entry("/w/README.md", file("README.md"), 0),
  ];
}

describe("filterBrowserRows", () => {
  test("hide dotfolders drops the folder and everything loaded under it", () => {
    expect(names(filterBrowserRows(tree(), { ...off, hideDotFolders: true }))).toEqual([
      "src",
      "foo.ts",
      "lib",
      "bar.ts",
      "util.ts",
      ".gitignore",
      "README.md",
    ]);
  });

  test("hide dotfiles drops files that start with a period and keeps dotfolders", () => {
    expect(names(filterBrowserRows(tree(), { ...off, hideDotFiles: true }))).toEqual([
      "src",
      "foo.ts",
      "lib",
      "bar.ts",
      "util.ts",
      ".git",
      "config",
      "HEAD",
      "README.md",
    ]);
  });

  test("both toggles hide every name that starts with a period", () => {
    expect(names(filterBrowserRows(tree(), { hideDotFolders: true, hideDotFiles: true, query: "" }))).toEqual([
      "src",
      "foo.ts",
      "lib",
      "bar.ts",
      "util.ts",
      "README.md",
    ]);
  });

  test("a name with a period later is not a dotfile", () => {
    const rows = [entry("/w/foo.bar", file("foo.bar"), 0), entry("/w/.env.local", file(".env.local"), 0)];
    expect(names(filterBrowserRows(rows, { ...off, hideDotFiles: true }))).toEqual(["foo.bar"]);
  });

  test("a symlink is a file for the dotfile toggle", () => {
    const rows = [entry("/w/.env", link(".env"), 0), entry("/w/README.md", file("README.md"), 0)];
    expect(names(filterBrowserRows(rows, { ...off, hideDotFiles: true }))).toEqual(["README.md"]);
  });

  test("the text filter is a case-insensitive substring of the name", () => {
    expect(names(filterBrowserRows(tree(), { ...off, query: "READ" }))).toEqual(["README.md"]);
    expect(names(filterBrowserRows(tree(), { ...off, query: "md" }))).toEqual(["README.md"]);
    expect(names(filterBrowserRows(tree(), { ...off, query: "  Bar  " }))).toEqual(["src", "lib", "bar.ts"]);
  });

  test("parent folders of a matching descendant stay visible", () => {
    expect(names(filterBrowserRows(tree(), { ...off, query: "bar" }))).toEqual(["src", "lib", "bar.ts"]);
  });

  test("a matching folder keeps its parents and not children that do not match", () => {
    expect(names(filterBrowserRows(tree(), { ...off, query: "lib" }))).toEqual(["src", "lib"]);
  });

  test("non-matching siblings of a hit are hidden", () => {
    expect(names(filterBrowserRows(tree(), { ...off, query: "foo" }))).toEqual(["src", "foo.ts"]);
  });

  test("a collapsed folder's children are not in the rows and do not match", () => {
    const collapsed = [entry("/w/src", dir("src"), 0, false), entry("/w/README.md", file("README.md"), 0)];
    expect(names(filterBrowserRows(collapsed, { ...off, query: "foo" }))).toEqual([]);
    expect(names(filterBrowserRows(collapsed, { ...off, query: "src" }))).toEqual(["src"]);
  });

  test("a query finds a match loaded under a folder the empty list would hide", () => {
    expect(names(filterBrowserRows(tree(), { hideDotFolders: true, hideDotFiles: false, query: "config" }))).toEqual([
      ".git",
      "config",
    ]);
  });

  test("a query finds matching names that start with a period even while they are hidden", () => {
    expect(names(filterBrowserRows(tree(), { hideDotFolders: false, hideDotFiles: true, query: "git" }))).toEqual([
      ".git",
      ".gitignore",
    ]);
  });

  test("query plus both toggles", () => {
    expect(names(filterBrowserRows(tree(), { hideDotFolders: true, hideDotFiles: true, query: "HEAD" }))).toEqual([
      ".git",
      "HEAD",
    ]);
    expect(names(filterBrowserRows(tree(), { hideDotFolders: true, hideDotFiles: true, query: "foo" }))).toEqual([
      "src",
      "foo.ts",
    ]);
  });

  test("status rows under a kept parent stay; an empty root does not count as a match", () => {
    const loading: BrowserRow[] = [
      entry("/w/src", dir("src"), 0, true),
      { kind: "LoadingRow", depth: 1 },
      { kind: "EmptyRow", depth: 0 },
    ];
    expect(filterBrowserRows(loading, { ...off, query: "src" })).toEqual(loading.slice(0, 2));
    expect(filterBrowserRows([{ kind: "EmptyRow", depth: 0 }], { ...off, query: "x" })).toEqual([]);
    const failed: BrowserRow[] = [{ kind: "FailedRow", depth: 0, dir: "/w", error: "no" }];
    expect(filterBrowserRows(failed, { ...off, query: "x" })).toEqual(failed);
  });
});

describe("fileBrowserNoMatches", () => {
  test("no rows left is a miss, including when the query is empty", () => {
    expect(fileBrowserNoMatches([])).toBe(true);
  });

  test("a remaining file, load, error or empty-folder row is not a miss", () => {
    expect(fileBrowserNoMatches([entry("/w/src", dir("src"), 0)])).toBe(false);
    expect(fileBrowserNoMatches([{ kind: "LoadingRow", depth: 0 }])).toBe(false);
    expect(fileBrowserNoMatches([{ kind: "FailedRow", depth: 0, dir: "/w", error: "no" }])).toBe(false);
    expect(fileBrowserNoMatches([{ kind: "EmptyRow", depth: 0 }])).toBe(false);
  });
});
