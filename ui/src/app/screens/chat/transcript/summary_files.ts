// Port of the logic of lib/screens/chat/transcript/summary_files.dart; its widget is summary_files_view.tsx.

/** What the summarized turns did to a file, as omp's compaction lists it. */
export type SummaryFileOperation = "read" | "write" | "readWrite" | "unknown";

/** A file omp's compaction summary lists. */
export interface SummaryFile {
  readonly path: string;
  readonly operation: SummaryFileOperation;
}

const block = /<(files|read-files|modified-files)>\n?([\s\S]*?)<\/\1>\s*/g;
const heading = /^(#+) (.+)$/;
const entry = /^(.+) \((Read|Write|RW)\)$/;
const elidedLine = /^\[…(\d+) files? elided…\]$/;

/**
 * A compaction summary split into its prose and the file lists omp appends to it (`packages/agent/src/compaction`): a
 * `<files>` block of `name (Read|Write|RW)` lines under `#`-per-depth directory headings, ending with a
 * `[…N files elided…]` line when capped, and the older `<read-files>` and `<modified-files>` blocks of one path per
 * line. `elided` counts the files omp left out.
 */
export function splitSummaryFiles(summary: string): { text: string; files: SummaryFile[]; elided: number } {
  const files: SummaryFile[] = [];
  let elided = 0;
  const text = summary.replace(block, (_match, tag: string, body: string) => {
    const lines = body
      .split("\n")
      .map((line) => line.trim())
      .filter((line) => line.length > 0);
    switch (tag) {
      case "read-files":
        for (const path of lines) files.push({ path, operation: "read" });
        break;
      case "modified-files":
        for (const path of lines) files.push({ path, operation: "write" });
        break;
      default: {
        const directories: string[] = [];
        for (const line of lines) {
          const count = elidedLine.exec(line);
          if (count !== null) {
            elided += Number.parseInt(count[1]!, 10);
            continue;
          }
          const title = heading.exec(line);
          if (title !== null) {
            const depth = title[1]!.length - 1;
            if (directories.length > depth) directories.length = depth;
            const name = title[2]!;
            directories.push(name.endsWith("/") ? name : `${name}/`);
            continue;
          }
          const file = entry.exec(line);
          files.push({ path: `${directories.join("")}${file?.[1] ?? line}`, operation: operationOf(file?.[2]) });
        }
      }
    }
    return "";
  });
  return { text: text.trimEnd(), files, elided };
}

function operationOf(name: string | undefined): SummaryFileOperation {
  switch (name) {
    case "Read":
      return "read";
    case "Write":
      return "write";
    case "RW":
      return "readWrite";
    default:
      return "unknown";
  }
}
