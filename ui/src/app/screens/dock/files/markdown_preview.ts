/**
 * `text` as the preview renders it: a leading YAML front matter block (`---` up to a `---` or `...` line, as omp's
 * skills and agents start) becomes a `yaml` code block, which markdown would otherwise render as rules around a run-on
 * paragraph. An empty block goes.
 */
export function frontMatterAsCode(text: string): string {
  if (!text.startsWith("---\n")) return text;
  const body = text.substring(4);
  const end = /^(?:---|\.\.\.)[ \t]*$/m.exec(body);
  if (end === null) return text;
  const yaml = body.substring(0, end.index).replace(/\n$/, "");
  const rest = body.substring(end.index + end[0].length).replace(/^\n/, "");
  if (yaml.trim() === "") return rest;
  const longestRun = Math.max(0, ...(yaml.match(/`+/g) ?? []).map((run) => run.length));
  const fence = "`".repeat(Math.max(3, longestRun + 1));
  return `${fence}yaml\n${yaml}\n${fence}\n\n${rest}`;
}
