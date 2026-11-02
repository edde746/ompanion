import { expect, test } from "bun:test";
import { gitStatusChangeOf, parseGitStatus } from "./git_status";

test("porcelain v1 -z: changes by absolute path, renames skip their source, dirty folders up to the root", () => {
  const porcelain = [
    " M README.md",
    "A  src/new.ts",
    "R  src/moved.ts",
    "src/old.ts",
    "?? notes/",
    "!! build/",
    "UU conflict.txt",
    " D gone.txt",
    "MM both.txt",
    "",
  ].join("\u0000");
  const status = parseGitStatus("/repo/", porcelain);
  expect(status.root).toBe("/repo");
  expect(Object.fromEntries(status.files)).toEqual({
    "/repo/README.md": "modified",
    "/repo/src/new.ts": "added",
    "/repo/src/moved.ts": "renamed",
    "/repo/notes": "untracked",
    "/repo/build": "ignored",
    "/repo/conflict.txt": "conflicted",
    "/repo/gone.txt": "deleted",
    "/repo/both.txt": "modified",
  });
  expect([...status.dirty].sort()).toEqual(["/repo", "/repo/src"]);
});

test("a file inside an untracked or ignored folder takes the folder's change; others have none", () => {
  const status = parseGitStatus("/repo", "?? notes/\u0000!! build/\u0000 M src/a.ts\u0000");
  expect(gitStatusChangeOf(status, "/repo/notes/today.md")).toBe("untracked");
  expect(gitStatusChangeOf(status, "/repo/build/out/app.js")).toBe("ignored");
  expect(gitStatusChangeOf(status, "/repo/src/a.ts")).toBe("modified");
  expect(gitStatusChangeOf(status, "/repo/src/b.ts")).toBeUndefined();
  expect(gitStatusChangeOf(status, "/elsewhere/x")).toBeUndefined();
});

test("no changes: nothing is dirty", () => {
  const status = parseGitStatus("/repo", "");
  expect(status.files.size).toBe(0);
  expect(status.dirty.size).toBe(0);
});
