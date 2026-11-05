import { expect, test } from "bun:test";
import { decodeMessage, type FileMentionItem } from "./transcript";

function folders(...contents: (string | undefined)[]): boolean[] {
  const item = decodeMessage({
    role: "fileMention",
    timestamp: 1,
    files: contents.map((content, index) => ({
      path: `p${index}`,
      lineCount: 1,
      ...(content === undefined ? {} : { content }),
    })),
  }) as FileMentionItem;
  return item.files.map((file) => file.folder);
}

test("a mentioned directory is told from a file by omp's listing of it", () => {
  expect(
    folders(
      "(empty directory)",
      "routes/ (2d ago)\nserver.ts (just now)\nREADME.md (3mo ago)",
      "a.ts (1h ago)\n\n[500 entries limit reached]",
      "export const x = 1;",
      "first line\nlast (2d ago)",
      undefined,
      "",
    ),
  ).toEqual([true, true, true, false, false, false, false]);
});
