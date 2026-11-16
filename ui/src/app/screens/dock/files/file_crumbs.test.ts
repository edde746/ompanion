import { describe, expect, test } from "bun:test";
import { breadcrumbs } from "../../../files/file_paths";
import { crumbKind } from "./file_crumbs";

describe("crumbKind", () => {
  test("in the browser, ancestors open a folder and the last segment is current", () => {
    expect(crumbKind(0, 3)).toBe("openDir");
    expect(crumbKind(1, 3)).toBe("openDir");
    expect(crumbKind(2, 3)).toBe("current");
  });

  test("a single browser crumb, including ~ at home, is current", () => {
    expect(crumbKind(0, 1)).toBe("current");
  });

  test("in the file viewer the first segment opens that folder", () => {
    const crumbs = breadcrumbs("/Users/edde/code/api-server/src/upload.ts", "/Users/edde");
    expect(crumbs.map((crumb) => crumb.label)).toEqual(["~", "code", "api-server", "src", "upload.ts"]);
    expect(crumbKind(0, crumbs.length)).toBe("openDir");
    expect(crumbs[0]?.path).toBe("/Users/edde");
    expect(crumbKind(1, crumbs.length)).toBe("openDir");
    expect(crumbKind(3, crumbs.length)).toBe("openDir");
    expect(crumbKind(4, crumbs.length)).toBe("current");
  });

  test("a file in the home directory makes ~ open the home folder", () => {
    const crumbs = breadcrumbs("/Users/edde/README.md", "/Users/edde");
    expect(crumbs.map((crumb) => crumb.label)).toEqual(["~", "README.md"]);
    expect(crumbKind(0, crumbs.length)).toBe("openDir");
    expect(crumbs[0]?.path).toBe("/Users/edde");
    expect(crumbKind(1, crumbs.length)).toBe("current");
  });

  test("outside the home the first segment opens the root", () => {
    const crumbs = breadcrumbs("/etc/hosts");
    expect(crumbs[0]?.label).toBe("/");
    expect(crumbs[0]?.path).toBe("/");
    expect(crumbKind(0, crumbs.length)).toBe("openDir");
    expect(crumbKind(1, crumbs.length)).toBe("openDir");
    expect(crumbKind(2, crumbs.length)).toBe("current");
  });
});
