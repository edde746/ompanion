/**
 * `text` as the preview renders it: a leading YAML front matter block (`---` up to a `---` or `...` line, as omp's
 * skills and agents start) becomes a `yaml` code block, which markdown would otherwise render as rules around a run-on
 * paragraph. An empty block goes, and so does a byte order mark, which the document keeps for saving.
 */
export function frontMatterAsCode(text: string): string {
  const source = text.startsWith("\uFEFF") ? text.substring(1) : text;
  if (!source.startsWith("---\n")) return source;
  const body = source.substring(4);
  const end = /^(?:---|\.\.\.)[ \t]*$/m.exec(body);
  if (end === null) return source;
  const yaml = body.substring(0, end.index).replace(/\n$/, "");
  const rest = body.substring(end.index + end[0].length).replace(/^\n/, "");
  if (yaml.trim() === "") return rest;
  const longestRun = Math.max(0, ...(yaml.match(/`+/g) ?? []).map((run) => run.length));
  const fence = "`".repeat(Math.max(3, longestRun + 1));
  return `${fence}yaml\n${yaml}\n${fence}\n\n${rest}`;
}
