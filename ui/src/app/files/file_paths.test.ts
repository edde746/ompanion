// Port of the path cases of test/dock/file_paths_test.dart.
import { describe, expect, test } from "bun:test";
import { languageFor } from "./file_language";
import {
  baseName,
  breadcrumbs,
  checkName,
  extensionOf,
  isRootPath,
  joinPath,
  normalizePath,
  parentPath,
  relativePath,
  resolveMachinePath,
} from "./file_paths";

describe("paths", () => {
  test("normalize collapses slashes, dots and parents; drive roots keep their slash", () => {
    expect(normalizePath("/a//b/./c/../d/")).toBe("/a/b/d");
    expect(normalizePath("/../..")).toBe("/");
    expect(normalizePath("/C:")).toBe("/C:/");
    expect(normalizePath("/C:/Users/../")).toBe("/C:/");
    expect(normalizePath("a/b/..")).toBe("a");
    expect(normalizePath("")).toBe(".");
  });

  test("parent and base name", () => {
    expect(parentPath("/home/omp/project")).toBe("/home/omp");
    expect(parentPath("/home")).toBe("/");
    expect(parentPath("/")).toBe("/");
    expect(parentPath("/C:/Users")).toBe("/C:/");
    expect(parentPath("/C:/")).toBe("/");
    expect(baseName("/home/omp/README.md")).toBe("README.md");
    expect(baseName("/C:/")).toBe("C:");
    expect(baseName("/")).toBe("/");
    expect(joinPath("/", "etc")).toBe("/etc");
    expect(joinPath("/C:/", "Users")).toBe("/C:/Users");
    expect(joinPath("/home", "omp")).toBe("/home/omp");
  });

  test("breadcrumbs lead from the root to the directory; a drive is one crumb", () => {
    expect(breadcrumbs("/home/omp/demo-project")).toEqual([
      { label: "/", path: "/" },
      { label: "home", path: "/home" },
      { label: "omp", path: "/home/omp" },
      { label: "demo-project", path: "/home/omp/demo-project" },
    ]);
    expect(breadcrumbs("/C:/Users/x")).toEqual([
      { label: "/", path: "/" },
      { label: "C:", path: "/C:/" },
      { label: "Users", path: "/C:/Users" },
      { label: "x", path: "/C:/Users/x" },
    ]);
    expect(breadcrumbs("/")).toEqual([{ label: "/", path: "/" }]);
  });

  test("breadcrumbs inside the home start at ~; outside it, and with a root home, at /", () => {
    expect(breadcrumbs("/Users/edde/code/api-server", "/Users/edde")).toEqual([
      { label: "~", path: "/Users/edde" },
      { label: "code", path: "/Users/edde/code" },
      { label: "api-server", path: "/Users/edde/code/api-server" },
    ]);
    expect(breadcrumbs("/Users/edde/", "/Users/edde")).toEqual([{ label: "~", path: "/Users/edde" }]);
    expect(breadcrumbs("/C:/Users/x/src", "/C:/Users/x")).toEqual([
      { label: "~", path: "/C:/Users/x" },
      { label: "src", path: "/C:/Users/x/src" },
    ]);
    expect(breadcrumbs("/Users/eddie", "/Users/edde")).toEqual([
      { label: "/", path: "/" },
      { label: "Users", path: "/Users" },
      { label: "eddie", path: "/Users/eddie" },
    ]);
    expect(breadcrumbs("/etc", "/")).toEqual([
      { label: "/", path: "/" },
      { label: "etc", path: "/etc" },
    ]);
  });

  test("relative paths only inside the root", () => {
    expect(relativePath("/home/omp", "/home/omp/a/b")).toBe("a/b");
    expect(relativePath("/home/omp", "/home/omp")).toBe(".");
    expect(relativePath("/home/omp", "/home/omphalos")).toBeUndefined();
    expect(relativePath("/", "/etc")).toBe("etc");
  });

  test("extensions and names", () => {
    expect(extensionOf("main.DART")).toBe("dart");
    expect(extensionOf(".bashrc")).toBe("");
    expect(extensionOf("Makefile")).toBe("");
    expect(extensionOf("archive.tar.gz")).toBe("gz");
    expect(checkName("ok.txt")).toBeUndefined();
    expect(checkName("  ")).toBe("empty");
    expect(checkName("..")).toBe("reserved");
    expect(checkName("a/b")).toBe("separator");
    expect(checkName("a\\b")).toBe("separator");
  });

  test("isRootPath", () => {
    expect(isRootPath("/")).toBe(true);
    expect(isRootPath("/D:/")).toBe(true);
    expect(isRootPath("/D:/x")).toBe(false);
  });

  test("transcript paths resolve against the home and the session directory", () => {
    const posix = (path: string, cwd: string | undefined = "/home/u/proj") =>
      resolveMachinePath(path, { home: "/home/u", cwd });
    expect(posix("/var/log/a.png")).toBe("/var/log/a.png");
    expect(posix("~/Pictures/a.png")).toBe("/home/u/Pictures/a.png");
    expect(posix("~")).toBe("/home/u");
    expect(posix("out/chart.png")).toBe("/home/u/proj/out/chart.png");
    expect(posix("./out/../chart.png")).toBe("/home/u/proj/chart.png");
    expect(resolveMachinePath("chart.png", { home: "/home/u", cwd: undefined })).toBe("/home/u/chart.png");
    // A backslash is a name character on POSIX.
    expect(posix("dir\\a.png")).toBe("/home/u/proj/dir\\a.png");
  });

  test("on a Windows machine drives, backslashes and ~ resolve in SFTP form", () => {
    const windows = (path: string) =>
      resolveMachinePath(path, { home: "C:\\Users\\u", cwd: "D:\\work\\proj", windows: true });
    expect(windows("C:\\Temp\\shot.png")).toBe("/C:/Temp/shot.png");
    expect(windows("C:/Temp/shot.png")).toBe("/C:/Temp/shot.png");
    expect(windows("~\\Pictures\\a.png")).toBe("/C:/Users/u/Pictures/a.png");
    expect(windows("out\\chart.png")).toBe("/D:/work/proj/out/chart.png");
    expect(windows("..\\chart.png")).toBe("/D:/work/chart.png");
  });
});

// The ids are Shiki's (the web highlighter), where the Dart test names highlight.js ids.
test("languages from file names", () => {
  expect(languageFor("main.dart")).toBe("dart");
  expect(languageFor("App.tsx")).toBe("tsx");
  expect(languageFor("setup.py")).toBe("python");
  expect(languageFor("config.yml")).toBe("yaml");
  expect(languageFor("Dockerfile")).toBe("docker");
  expect(languageFor("Dockerfile.dev")).toBe("docker");
  expect(languageFor("Makefile")).toBe("make");
  expect(languageFor(".zshrc")).toBe("shellscript");
  expect(languageFor("Gemfile")).toBe("ruby");
  expect(languageFor("lib.rs")).toBe("rust");
  expect(languageFor("README.md")).toBe("markdown");
  expect(languageFor("main.go")).toBe("go");
  expect(languageFor("data.unknownext")).toBeUndefined();
  expect(languageFor("LICENSE")).toBeUndefined();
});
