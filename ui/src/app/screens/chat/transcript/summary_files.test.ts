// Port of test/transcript/summary_files_test.dart.
import { expect, test } from "bun:test";
import { splitSummaryFiles } from "./summary_files";

test("omp's <files> block becomes paths under their directory headings, out of the prose", () => {
  const summary = splitSummaryFiles(
    "## Summary\nDid things.\n\n<files>\nREADME.md (Read)\n# lib/\nmain.dart (RW)\n## screens/chat/\nchat.dart (Write)\n" +
      "# test/\nmain_test.dart (Read)\n[…3 files elided…]\n</files>\n",
  );
  expect(summary.text).toBe("## Summary\nDid things.");
  expect(summary.files).toEqual([
    { path: "README.md", operation: "read" },
    { path: "lib/main.dart", operation: "readWrite" },
    { path: "lib/screens/chat/chat.dart", operation: "write" },
    { path: "test/main_test.dart", operation: "read" },
  ]);
  expect(summary.elided).toBe(3);
});

test("the older read-files and modified-files blocks", () => {
  const summary = splitSummaryFiles("Text\n<read-files>\na.md\n</read-files>\n<modified-files>\nb.md\n</modified-files>");
  expect(summary.text).toBe("Text");
  expect(summary.files).toEqual([
    { path: "a.md", operation: "read" },
    { path: "b.md", operation: "write" },
  ]);
});
