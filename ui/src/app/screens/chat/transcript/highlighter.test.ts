// Port of test/transcript/highlighter_test.dart.
import { expect, test } from "bun:test";
import { CodeHighlighter, highlightedSpans, languageForFence, languageForPath } from "./highlighter";

const highlighter = CodeHighlighter.instance;

test("code is highlighted, then served from the cache", async () => {
  const code = "void main() {\n  print(1);\n}";
  const runs = await highlighter.highlight("dart", code);
  expect(runs).toBeDefined();
  if (runs === undefined) return;
  const spans = highlightedSpans(code, runs);
  expect(spans.map((span) => span.text).join("")).toBe(code);
  const styled = spans.filter((span) => span.class !== undefined).map((span) => span.text.trim());
  expect(styled).toEqual(expect.arrayContaining(["void", "print", "1"]));
  expect(highlighter.isCached("dart", code)).toBe(true);
  expect(highlighter.cached("dart", code)).toBe(runs);
});

test("TextMate scopes take the syntax token of their Atom One group", async () => {
  const code = 'const greeting: string = "hi"; // say it\nfunction answer() { return 42 || null; }';
  const runs = await highlighter.highlight("typescript", code);
  expect(runs).toBeDefined();
  if (runs === undefined) return;
  const classes = new Map(highlightedSpans(code, runs).map((span) => [span.text.trim(), span.class]));
  expect(classes.get("const")).toBe("code-style-keyword");
  expect(classes.get("string")).toBe("code-style-built-in");
  expect(classes.get('"hi"')).toBe("code-style-string");
  expect(classes.get("// say it")).toBe("code-style-comment");
  expect(classes.get("answer")).toBe("code-style-title");
  expect(classes.get("42")).toBe("code-style-number");
  expect(classes.get("null")).toBe("code-style-literal");
  // Operators keep the text colour, as highlight.js leaves them unscoped.
  expect(classes.get("||")).toBeUndefined();
});

test("syntax tokens become their code_style classes; text past the runs stays plain", () => {
  const runs = { ends: Int32Array.from([5, 9, 13]), scopes: ["built-in", "title", "comment"] };
  expect(highlightedSpans("Klass foo // x", runs)).toEqual([
    { text: "Klass", class: "code-style-built-in" },
    { text: " foo", class: "code-style-title" },
    { text: " // ", class: "code-style-comment" },
    { text: "x" },
  ]);
  // Runs of a longer code (a block shown without its last newline) stop at the code's end.
  expect(highlightedSpans("ab", { ends: Int32Array.from([1, 3]), scopes: [undefined, "string"] })).toEqual([
    { text: "a" },
    { text: "b" },
  ]);
});

test("an unknown language completes without runs", async () => {
  expect(await highlighter.highlight("no-such-language", "x")).toBeUndefined();
});

test("nginx and GLSL, whose grammars do not ship, stay plain; C++ highlights without GLSL", async () => {
  expect([languageForFence("nginx"), languageForFence("glsl"), languageForPath("shader.glsl")]).toEqual([
    undefined,
    undefined,
    undefined,
  ]);
  expect(await highlighter.highlight("nginx", "server { listen 80; }")).toBeUndefined();
  const code = 'int main() { return printf("%d", 1); }';
  const runs = await highlighter.highlight("cpp", code);
  expect(runs).toBeDefined();
  if (runs === undefined) return;
  const styled = highlightedSpans(code, runs).filter((span) => span.class !== undefined).map((span) => span.text.trim());
  expect(styled).toEqual(expect.arrayContaining(["int", "return", "1"]));
});

test("an unknown language stays cached when the block asks again", async () => {
  const language = "not-a-language";
  const code = "graph TD\n  A --> B";
  await highlighter.highlight(language, code);
  expect(highlighter.isCached(language, code)).toBe(true);

  // A block scrolled back into view reads the cache, then asks again.
  expect(highlighter.cached(language, code)).toBeUndefined();
  expect(highlighter.isCached(language, code)).toBe(true);
  expect(await highlighter.highlight(language, code)).toBeUndefined();
  expect(highlighter.isCached(language, code)).toBe(true);
});

test("one request per language and code is in flight at a time", async () => {
  const code = '{"a": [1, 2]}';
  const first = highlighter.highlight("json", code);
  expect(highlighter.highlight("json", code)).toBe(first);
  expect(await first).toBeDefined();
});

test("code too long to highlight quickly stays plain and is not cached", async () => {
  const code = "x = 1\n".repeat(5000);
  expect(await highlighter.highlight("python", code)).toBeUndefined();
  expect(highlighter.isCached("python", code)).toBe(false);
});

test("a chunk goes on in the grammar state the chunk before it ended in", async () => {
  const first = await highlighter.highlightChunk("typescript", "const a = 1; /* a comment\n");
  expect(first).toBeDefined();
  if (first === undefined) return;
  const code = "still the comment */ let b;";
  const second = await highlighter.highlightChunk("typescript", code, first.state);
  expect(second).toBeDefined();
  if (second === undefined) return;
  expect(highlightedSpans(code, second.runs)[0]).toEqual({ text: "still the comment */", class: "code-style-comment" });
  expect(highlighter.isCached("typescript", code)).toBe(false);
  expect(await highlighter.highlightChunk("no-such-language", code)).toBeUndefined();
});

test("fence infos and paths map to Shiki languages", () => {
  expect([
    languageForFence("ts"),
    languageForFence("shell"),
    languageForFence(" Python "),
    languageForFence("text"),
    languageForFence("cobol"),
    languageForFence(undefined),
  ]).toEqual(["typescript", "shellscript", "python", undefined, undefined, undefined]);
  expect([
    languageForPath("lib/main.dart"),
    languageForPath("/x/Dockerfile"),
    languageForPath("C:\\src\\app.TSX"),
    languageForPath("README"),
    languageForPath("a."),
    languageForPath(".bashrc"),
  ]).toEqual(["dart", "docker", "tsx", undefined, undefined, undefined]);
});
