// Port of test/transcript/markdown_test.dart: the parser cases run on `markdownBlocks`, which cuts a text where the
// block syntaxes start and end; the rhythm cases on the gaps between its blocks.
import { describe, expect, test } from "bun:test";
import {
  blockGap,
  type CustomBlock,
  fitColumns,
  machineImagePath,
  type MarkdownBlock,
  markdownBlocks,
  rewriteDollarMath,
  splitStreamSegments,
  transcriptLinkTarget,
} from "./blocks";

function fence(block: MarkdownBlock | undefined): Extract<CustomBlock, { kind: "CommonMarkFence" }> {
  const custom = block?.custom;
  if (custom?.kind !== "CommonMarkFence") throw new Error(`not a fence: ${block?.text}`);
  return custom;
}

describe("CommonMarkFence", () => {
  test("a backtick fence with an info string", () => {
    const blocks = markdownBlocks('before\n\n```dart title="x"\nvoid main() {}\n```\n\nafter');
    expect(blocks).toHaveLength(3);
    expect(fence(blocks[1]).body).toBe("void main() {}");
    expect(fence(blocks[1]).info).toBe('dart title="x"');
    expect(fence(blocks[1]).closed).toBe(true);
    expect(blocks[2]).toEqual({ text: "after", heading: false, list: undefined, custom: undefined });
  });

  test("a tilde fence", () => {
    const blocks = markdownBlocks("~~~python\nprint(1)\n~~~");
    expect(blocks).toHaveLength(1);
    expect(fence(blocks[0]).char).toBe("~");
    expect(fence(blocks[0]).body).toBe("print(1)");
  });

  test("a longer fence keeps shorter fences as content", () => {
    const blocks = markdownBlocks("````markdown\n```bash\nls\n```\n````\ntail");
    expect(fence(blocks[0]).body).toBe("```bash\nls\n```");
    expect(fence(blocks[0]).closed).toBe(true);
    expect(blocks.at(-1)).toEqual({ text: "tail", heading: false, list: undefined, custom: undefined });
  });

  test("a tilde fence is not closed by backticks and the reverse", () => {
    expect(fence(markdownBlocks("~~~\n```\n~~~")[0]).body).toBe("```");
    expect(fence(markdownBlocks("```\n~~~\n```")[0]).body).toBe("~~~");
  });

  test("a closing line with text after the fence does not close it", () => {
    const blocks = markdownBlocks("```\na\n``` not a closer\nb\n```");
    expect(blocks).toHaveLength(1);
    expect(fence(blocks[0]).body).toBe("a\n``` not a closer\nb");
  });

  test("an unclosed fence runs to the end while it streams", () => {
    const block = fence(markdownBlocks("text\n\n```ts\nconst a = 1;\nconst b").at(-1));
    expect(block.closed).toBe(false);
    expect(block.body).toBe("const a = 1;\nconst b");
  });

  test("the opener's indentation is removed from the content", () => {
    const blocks = markdownBlocks("   ```\n   indented\n  less\n     more\n   ```");
    expect(blocks).toHaveLength(1);
    expect(fence(blocks[0]).body).toBe("indented\nless\n  more");
  });

  test("a backtick info string containing a backtick is not a fence", () => {
    expect(markdownBlocks("```a`b\ntext")[0]?.custom).toBeUndefined();
  });

  test("a fence inside a list item stays in its item", () => {
    const blocks = markdownBlocks("1. Run:\n   ```bash\n   npm install\n   ```\n2. Done");
    expect(blocks.map((block) => [block.text, block.list])).toEqual([
      ["1. Run:\n   ```bash\n   npm install\n   ```", "10"],
      ["2. Done", "10"],
    ]);
  });

  test("the streaming segment splitter keeps a fence with blank lines in one segment", () => {
    expect(splitStreamSegments("a\n\n````md\n```\nx\n\ny\n```\n````\n\nb")).toEqual([
      "a",
      "````md\n```\nx\n\ny\n```\n````",
      "b",
    ]);
  });
});

describe("PipeTable", () => {
  test("header, alignments and body rows up to the first line without a pipe", () => {
    const blocks = markdownBlocks("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 |\n| x \\| y | z | w | extra |\nafter");
    expect(blocks[0]?.custom).toEqual({
      kind: "PipeTable",
      table: {
        aligns: ["left", "center", "right"],
        rows: [
          ["a", "b", "c"],
          ["1", "2", ""],
          ["x | y", "z", "w"],
        ],
      },
    });
    expect(blocks.at(-1)).toEqual({ text: "after", heading: false, list: undefined, custom: undefined });
  });

  test("without a complete delimiter row, as while it streams, it is not a table yet", () => {
    expect(markdownBlocks("| a | b |\n|---|:")[0]?.custom).toBeUndefined();
    expect(markdownBlocks("| a | b |")[0]?.custom).toBeUndefined();
  });

  // The widget test's case: a path over half the table's width and a change beside it that wraps.
  test("a code span in a cell keeps its column wide enough while the other columns wrap for it", () => {
    const widths = fitColumns([260, 420], [260, 0], 476);
    expect(widths[0]).toBe(260);
    expect(widths[1]).toBeCloseTo(216, 3);
  });

  test("columns take their content when they fit, else the wide ones share one width above the floors", () => {
    expect(fitColumns([80, 200], [0, 0], 476)).toEqual([80, 200]);
    const widths = fitColumns([80, 400, 400], [0, 0, 0], 480);
    expect(widths[0]).toBe(80);
    expect(widths[1]).toBeCloseTo(200, 3);
    expect(widths[2]).toBeCloseTo(200, 3);
  });

  test("a table that cannot fit at its floors keeps them and scrolls sideways", () => {
    expect(fitColumns([300, 300, 60], [0, 180, 0], 300)).toEqual([120, 180, 60]);
  });
});

describe("TaskList", () => {
  test("consecutive items of one marker with their continuation lines", () => {
    const blocks = markdownBlocks("- [x] done\n- [ ] open\n  more\n- plain");
    expect(blocks[0]?.custom).toEqual({
      kind: "TaskList",
      items: [
        { checked: true, text: "done" },
        { checked: false, text: "open more" },
      ],
    });
    expect(blocks[1]).toEqual({ text: "- plain", heading: false, list: "-0", custom: undefined });
    expect(markdownBlocks("* [X] star")[0]?.custom).toEqual({ kind: "TaskList", items: [{ checked: true, text: "star" }] });
  });

  test("a bracketed link after a bullet is an ordinary list item", () => {
    const blocks = markdownBlocks("- [omp](https://example.com) docs");
    expect(blocks).toEqual([
      { text: "- [omp](https://example.com) docs", heading: false, list: "-0", custom: undefined },
    ]);
  });
});

describe("rewriteDollarMath", () => {
  test("inline and display math", () => {
    expect(rewriteDollarMath("Euler: $e^{i\\pi}+1=0$.")).toBe("Euler: \\(e^{i\\pi}+1=0\\).");
    expect(rewriteDollarMath("$$\n\\int_0^1 x\\,dx\n$$")).toBe("\\[\n\\int_0^1 x\\,dx\n\\]");
  });

  test("prices and lone dollars stay text", () => {
    expect(rewriteDollarMath("It costs $5 and $10 today.")).toBe("It costs $5 and $10 today.");
    expect(rewriteDollarMath("Pay $ 5 or $ 6")).toBe("Pay $ 5 or $ 6");
  });

  test("code spans and fences are left alone", () => {
    expect(rewriteDollarMath("Run `echo $HOME` then `echo $PATH`.")).toBe("Run `echo $HOME` then `echo $PATH`.");
    const fenced = "Math $x$\n\n```bash\necho $A $B\n```\n\n~~~\n$y$\n~~~\nand $z$";
    expect(rewriteDollarMath(fenced)).toBe("Math \\(x\\)\n\n```bash\necho $A $B\n```\n\n~~~\n$y$\n~~~\nand \\(z\\)");
  });

  test("an escaped dollar is not math", () => {
    expect(rewriteDollarMath("\\$x\\$ and $y$")).toBe("\\$x\\$ and \\(y\\)");
  });

  test("inline math does not cross lines", () => {
    expect(rewriteDollarMath("$a\nb$")).toBe("$a\nb$");
  });
});

describe("images", () => {
  const png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=";

  test("paths name machine images; data, web and other URLs do not", () => {
    expect(machineImagePath("/home/u/out/chart.png")).toBe("/home/u/out/chart.png");
    expect(machineImagePath("~/shots/a.png")).toBe("~/shots/a.png");
    expect(machineImagePath("out/chart%20v2.png")).toBe("out/chart v2.png");
    expect(machineImagePath("./chart.png")).toBe("./chart.png");
    expect(machineImagePath("C:\\Users\\u\\shot.png")).toBe("C:\\Users\\u\\shot.png");
    expect(machineImagePath("C:/Users/u/shot.png")).toBe("C:/Users/u/shot.png");
    expect(machineImagePath("file:///home/u/a%20b.png")).toBe("/home/u/a b.png");
    expect(machineImagePath("file:///C:/Users/u/shot.png")).toBe("C:/Users/u/shot.png");
    expect(machineImagePath("file://host/srv/a.png")).toBe("/srv/a.png");
    expect(machineImagePath(`data:image/png;base64,${png}`)).toBeUndefined();
    expect(machineImagePath("https://example.com/a.png")).toBeUndefined();
    expect(machineImagePath("ftp://example.com/a.png")).toBeUndefined();
    expect(machineImagePath("")).toBeUndefined();
  });
});

describe("rhythm", () => {
  const gaps = (markdown: string) => {
    const blocks = markdownBlocks(markdown);
    return blocks.slice(1).map((block, index) => blockGap(blocks[index]!, block));
  };

  // The gaps inside an item (4 to its nested list, 6 between nested items, 8 from the last one to the next item) are
  // the list's own padding (markdown.css).
  test("blocks, headings and list items keep their gaps", () => {
    const text = [
      "The download client is fine.",
      "",
      "Seeders count for nothing.",
      "",
      "### Fixes",
      "1. **Radarr:**",
      "   - Set minimum seeders to ten on public indexers and leave private trackers at one.",
      "   - Point the indexer at trans2.",
      "2. **4K profile:** put every 2160p quality into one group so releases compete on score.",
      "3. **Queue:** grab both.",
      "",
      "After those changes:",
      "```sh",
      "curl -s localhost:7878",
      "```",
      "",
      "That is all.",
    ].join("\n");
    expect(markdownBlocks(text).map((block) => block.text.split("\n")[0])).toEqual([
      "The download client is fine.",
      "Seeders count for nothing.",
      "### Fixes",
      "1. **Radarr:**",
      "2. **4K profile:** put every 2160p quality into one group so releases compete on score.",
      "3. **Queue:** grab both.",
      "After those changes:",
      "```sh",
      "That is all.",
    ]);
    // paragraph to paragraph, block to heading, heading to its list, item to item (twice), list to paragraph,
    // paragraph to code, code to paragraph.
    expect(gaps(text)).toEqual([12, 20, 8, 6, 6, 12, 12, 12]);
  });

  test("a text cut into parts keeps the gaps it has in one piece", () => {
    const cuts: [string, string][] = [
      ["Intro.\n\n### Fixes", "First fix."],
      ["Intro.", "## Next"],
      ["1. one\n   - nested", "2. two"],
      ["1. one", "- a bullet"],
    ];
    for (const [above, below] of cuts) {
      const whole = markdownBlocks(`${above}\n\n${below}`);
      const cut = markdownBlocks(above).length;
      const inOnePiece = blockGap(whole[cut - 1]!, whole[cut]!);
      const inParts = blockGap(markdownBlocks(above).at(-1)!, markdownBlocks(below)[0]!);
      expect(inParts).toBe(inOnePiece);
    }
  });
});

describe("links", () => {
  test("web, mail and any other scheme go to the system", () => {
    expect(transcriptLinkTarget("https://example.com/docs")).toEqual({ kind: "external", url: "https://example.com/docs" });
    expect(transcriptLinkTarget("mailto:dev@example.com")).toEqual({ kind: "external", url: "mailto:dev@example.com" });
    expect(transcriptLinkTarget("smb://evil.example/share/report")).toEqual({
      kind: "external",
      url: "smb://evil.example/share/report",
    });
  });

  test("paths open as files of the session's machine, a #L or :line suffix as the line", () => {
    expect(transcriptLinkTarget("src/main.ts")).toEqual({ kind: "file", path: "src/main.ts", line: undefined });
    expect(transcriptLinkTarget("src/main.ts#L12-L20")).toEqual({ kind: "file", path: "src/main.ts", line: 12 });
    expect(transcriptLinkTarget("main.ts:12")).toEqual({ kind: "file", path: "main.ts", line: 12 });
    expect(transcriptLinkTarget("main.ts:12:4")).toEqual({ kind: "file", path: "main.ts", line: 12 });
    expect(transcriptLinkTarget("file:///home/u/a%20b.md")).toEqual({ kind: "file", path: "/home/u/a b.md", line: undefined });
    expect(transcriptLinkTarget("C:/Users/u/a.txt")).toEqual({ kind: "file", path: "C:/Users/u/a.txt", line: undefined });
    expect(transcriptLinkTarget("100%.md")).toEqual({ kind: "file", path: "100%.md", line: undefined });
  });
});
