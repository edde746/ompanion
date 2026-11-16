import { describe, expect, test } from "bun:test";
import { parseFrontmatter } from "./frontmatter";

describe("parseFrontmatter", () => {
  test("leaves text without a fence as the body", () => {
    expect(parseFrontmatter("# Hello\n\nbody")).toEqual({ matter: undefined, body: "# Hello\n\nbody" });
    expect(parseFrontmatter("")).toEqual({ matter: undefined, body: "" });
  });

  test("does not treat an unclosed fence as frontmatter", () => {
    const text = "---\ntitle: Lost\n# still body";
    expect(parseFrontmatter(text)).toEqual({ matter: undefined, body: text });
  });

  test("strips a title, tags, aliases and other keys", () => {
    const text = `---
title: Meeting
tags:
  - work
  - "q3"
aliases: [standup]
created: 2024-01-15
status: draft
---
# Heading
`;
    const { matter, body } = parseFrontmatter(text);
    expect(body).toBe("# Heading\n");
    expect(matter?.title).toBe("Meeting");
    expect(matter?.tags).toEqual(["work", "q3"]);
    expect(matter?.aliases).toEqual(["standup"]);
    expect(matter?.fields.map((field) => field.key)).toEqual(["created", "status"]);
    expect(matter?.fields.find((field) => field.key === "status")?.value).toBe("draft");
    expect(matter?.fields.find((field) => field.key === "created")?.value).toBe("2024-01-15");
  });

  test("an empty fence is properties without a title", () => {
    const { matter, body } = parseFrontmatter("---\n---\nHello");
    expect(body).toBe("Hello");
    expect(matter).toEqual({ title: undefined, tags: [], aliases: [], fields: [] });
  });

  test("invalid YAML reports an error without hiding the body", () => {
    const { matter, body, error } = parseFrontmatter("---\ntags: [unclosed\n---\nshown");
    expect(body).toBe("shown");
    expect(matter).toBeUndefined();
    expect(error).toBeDefined();
  });

  test("non-map properties report an error", () => {
    const { matter, body, error } = parseFrontmatter("---\n- a\n- b\n---\nshown");
    expect(body).toBe("shown");
    expect(matter).toBeUndefined();
    expect(error).toBeDefined();
  });

  test("a cyclic property reports an error instead of silently disappearing", () => {
    const { matter, body, error } = parseFrontmatter("---\ncustom: &custom {self: *custom}\n---\nshown");
    expect(body).toBe("shown");
    expect(matter).toBeUndefined();
    expect(error).toBeDefined();
  });

  test("accepts a BOM and a ... closer", () => {
    const { matter, body } = parseFrontmatter("\uFEFF---\ntitle: Bom\n...\nAfter");
    expect(matter?.title).toBe("Bom");
    expect(body).toBe("After");
  });

  test("comma-separated tags and a singular tag key join without duplicates", () => {
    const { matter } = parseFrontmatter("---\ntags: alpha, beta\ntag: beta\n---\n");
    expect(matter?.tags).toEqual(["alpha", "beta"]);
  });
});
