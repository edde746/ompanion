import { describe, expect, test } from "bun:test";
import { parseComment, parseHighlight, parseTag } from "./obsidian";

describe("parseHighlight", () => {
  test("takes ==text== on one line", () => {
    expect(parseHighlight("==hi==", 0)).toEqual({ content: "hi", end: 6 });
    expect(parseHighlight("x ==a b== y", 2)).toEqual({ content: "a b", end: 9 });
    expect(parseHighlight("==no", 0)).toBeUndefined();
    expect(parseHighlight("====", 0)).toBeUndefined();
    expect(parseHighlight("==a\nb==", 0)).toBeUndefined();
    expect(parseHighlight("not", 0)).toBeUndefined();
  });
});

describe("parseComment", () => {
  test("hides %%comments%%, including across lines", () => {
    expect(parseComment("a %%hide%% b", 2)).toEqual({ end: 10 });
    expect(parseComment("%%\nsecret\n%% visible", 0)).toEqual({ end: 12 });
    expect(parseComment("%%no close", 0)).toBeUndefined();
    expect(parseComment("%not", 0)).toBeUndefined();
  });
});

describe("parseTag", () => {
  test("reads #tag and #nested/tag after a boundary", () => {
    expect(parseTag("#work", 0)).toEqual({ tag: "work", end: 5 });
    expect(parseTag("see #nested/tag.", 4)).toEqual({ tag: "nested/tag", end: 15 });
    expect(parseTag("(#ok)", 1)).toEqual({ tag: "ok", end: 4 });
  });

  test("ignores headings, mid-word hashes and numeric hashes", () => {
    expect(parseTag("# Heading", 0)).toBeUndefined();
    expect(parseTag("## Heading", 0)).toBeUndefined();
    expect(parseTag("#123", 0)).toBeUndefined();
    expect(parseTag("c#tag", 1)).toBeUndefined();
    expect(parseTag("https://example.com/#frag", 20)).toBeUndefined();
  });
});
