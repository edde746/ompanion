import { describe, expect, test } from "bun:test";
import { MemoryFiles } from "../test/memory_host";
import {
  collectWikiTargets,
  findVaultRoot,
  headingId,
  isMarkdownPreviewFile,
  parseWikiLink,
  resolveWikilink,
  wikiLinkLabel,
  wikilinkCandidates,
} from "./wikilink";

describe("isMarkdownPreviewFile", () => {
  test("opens preview for markdown extensions only", () => {
    expect(isMarkdownPreviewFile("Note.md")).toBe(true);
    expect(isMarkdownPreviewFile("Note.markdown")).toBe(true);
    expect(isMarkdownPreviewFile("Note.mdx")).toBe(true);
    expect(isMarkdownPreviewFile("NOTE.MD")).toBe(true);
    expect(isMarkdownPreviewFile("note.txt")).toBe(false);
    expect(isMarkdownPreviewFile("note.md.bak")).toBe(false);
    expect(isMarkdownPreviewFile(".md")).toBe(false);
    expect(isMarkdownPreviewFile("README")).toBe(false);
  });
});

describe("parseWikiLink", () => {
  test("parses target, alias, heading and embed size", () => {
    expect(parseWikiLink("[[Note]]", 0)?.link).toEqual({
      target: "Note",
      heading: undefined,
      alias: undefined,
      embed: false,
      width: undefined,
    });
    expect(parseWikiLink("see [[Note|alias]] here", 4)?.link).toMatchObject({ target: "Note", alias: "alias" });
    expect(parseWikiLink("[[Note#Heading]]", 0)?.link).toMatchObject({ target: "Note", heading: "Heading" });
    expect(parseWikiLink("[[#Heading]]", 0)?.link).toMatchObject({ target: "", heading: "Heading" });
    expect(parseWikiLink("![[image.png|300]]", 0)?.link).toMatchObject({
      target: "image.png",
      embed: true,
      width: 300,
      alias: undefined,
    });
    expect(parseWikiLink("![[Other note]]", 0)?.link).toMatchObject({ target: "Other note", embed: true });
    expect(parseWikiLink("[[]]", 0)).toBeUndefined();
    expect(parseWikiLink("[Note]", 0)).toBeUndefined();
    expect(parseWikiLink("[[no close", 0)).toBeUndefined();
  });

  test("the label prefers the alias, then a heading, then the base name", () => {
    expect(wikiLinkLabel(parseWikiLink("[[folder/Note|Go]]", 0)!.link)).toBe("Go");
    expect(wikiLinkLabel(parseWikiLink("[[#Heading]]", 0)!.link)).toBe("Heading");
    expect(wikiLinkLabel(parseWikiLink("[[folder/Note]]", 0)!.link)).toBe("Note");
  });

  test("requires both closing brackets inside the inline parser's range", () => {
    expect(parseWikiLink("[[Note]]", 0, 7)).toBeUndefined();
    expect(parseWikiLink("[[Note]]", 0, 8)?.link.target).toBe("Note");
  });
});

describe("wikilinkCandidates", () => {
  test("tries the folder, then the vault root, adding markdown suffixes to a bare name", () => {
    expect(wikilinkCandidates("Note", { folder: "/vault/notes", vaultRoot: "/vault" })).toEqual([
      "/vault/notes/Note",
      "/vault/notes/Note.md",
      "/vault/notes/Note.markdown",
      "/vault/notes/Note.mdx",
      "/vault/Note",
      "/vault/Note.md",
      "/vault/Note.markdown",
      "/vault/Note.mdx",
    ]);
  });

  test("keeps a known extension and nested paths", () => {
    expect(wikilinkCandidates("img.png", { folder: "/vault/notes" })).toEqual(["/vault/notes/img.png"]);
    expect(wikilinkCandidates("folder/Note.md", { folder: "/vault", vaultRoot: "/vault" })).toEqual([
      "/vault/folder/Note.md",
    ]);
  });
});

describe("resolveWikilink and findVaultRoot", () => {
  test("resolves a note in the same folder before the vault root", async () => {
    const files = new MemoryFiles({
      "/vault/notes/Note.md": "here",
      "/vault/Note.md": "root",
    });
    files.dirs.add("/vault/.obsidian");
    const path = await resolveWikilink("Note", (target) => files.stat(target), {
      folder: "/vault/notes",
      vaultRoot: "/vault",
    });
    expect(path).toBe("/vault/notes/Note.md");
  });

  test("falls back to the vault root and leaves a miss unresolved", async () => {
    const files = new MemoryFiles({ "/vault/Home.md": "home" });
    files.dirs.add("/vault/.obsidian");
    const found = await resolveWikilink("Home", (target) => files.stat(target), {
      folder: "/vault/notes",
      vaultRoot: "/vault",
    });
    expect(found).toBe("/vault/Home.md");
    const missing = await resolveWikilink("Ghost", (target) => files.stat(target), { folder: "/vault/notes" });
    expect(missing).toBeUndefined();
  });

  test("finds the nearest ancestor that holds .obsidian and stops at home", async () => {
    const files = new MemoryFiles({ "/home/u/vault/notes/a.md": "a" });
    files.dirs.add("/home/u/vault/.obsidian");
    expect(await findVaultRoot("/home/u/vault/notes", (target) => files.stat(target), { stopAt: "/home/u" })).toBe(
      "/home/u/vault",
    );
    const none = new MemoryFiles({ "/home/u/project/readme.md": "x" });
    expect(
      await findVaultRoot("/home/u/project", (target) => none.stat(target), { stopAt: "/home/u" }),
    ).toBeUndefined();
  });
});

describe("headingId", () => {
  test("slugs a heading the way [[#Heading]] looks it up", () => {
    expect(headingId("Hello World")).toBe("hello-world");
    expect(headingId("hello-world")).toBe("hello-world");
    expect(headingId("  API / v2  ")).toBe("api-v2");
    expect(headingId("")).toBe("heading");
  });
});

describe("collectWikiTargets", () => {
  test("collects notes and skips fenced and inline code", () => {
    const source = [
      "See [[Note]] and [[Note#Heading|alias]] and [[#Here]].",
      "",
      "```",
      "[[InsideFence]]",
      "```",
      "",
      "Inline `[[InsideCode]]` and ![[image.png]] and [[Other]].",
    ].join("\n");
    expect(collectWikiTargets(source)).toEqual(["Note", "image.png", "Other"]);
  });
});
