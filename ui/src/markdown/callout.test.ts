import { describe, expect, test } from "bun:test";
import { parseCalloutLine } from "./callout";

describe("parseCalloutLine", () => {
  test("reads type, title and fold", () => {
    expect(parseCalloutLine("[!note] Title")).toMatchObject({ type: "note", title: "Title", fold: "none" });
    expect(parseCalloutLine("[!warning]-")).toMatchObject({
      type: "warning",
      title: undefined,
      fold: "closed",
    });
    expect(parseCalloutLine("[!tip]+ Extra")).toMatchObject({ type: "tip", title: "Extra", fold: "open" });
    expect(parseCalloutLine("  [!info]")).toMatchObject({ type: "info", title: undefined });
  });

  test("maps aliases and keeps unknown types", () => {
    expect(parseCalloutLine("[!hint] Go")?.type).toBe("tip");
    expect(parseCalloutLine("[!error]")?.type).toBe("danger");
    expect(parseCalloutLine("[!caution]")?.type).toBe("warning");
    expect(parseCalloutLine("[!custom-block] Hi")).toMatchObject({ type: "custom-block", title: "Hi" });
  });

  test("rejects ordinary quotes", () => {
    expect(parseCalloutLine("just a quote")).toBeUndefined();
    expect(parseCalloutLine("[note] not a callout")).toBeUndefined();
    expect(parseCalloutLine("[!]")).toBeUndefined();
  });
});
