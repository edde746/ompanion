// What a tool card knows about one call (lib/screens/chat/transcript/tool_card.dart's ToolData) and what its arguments
// and details say, per tool (the parsing of tool_bodies.dart). tool_card.tsx and tool_bodies.tsx show it.
import { isJsonObject, type JsonObject } from "../../../../core/rpc/json_fields";
import { decodeImage, type ImageBlock, isImageBlock, textOf } from "../../../../core/store/content";
import type {
  GoalStatus,
  Subagent,
  SubagentStatus,
  TodoStatus,
} from "../../../../core/store/session_view";
import type { ToolResultItem } from "../../../../core/store/transcript";
import { extensionOf } from "../../../files/file_paths";
import { t } from "../../../i18n/i18n";
import { formatBytes } from "../../../utils/byte_size";
import { type DiffLine, parseOmpDiff } from "./diff";
import { imageSize, type ImageSize } from "./images";
import { type ToolKind, toolKindFor, type ToolRow, toolRowAbandoned } from "./transcript_rows";

export type ToolStatus = "pending" | "running" | "background" | "done" | "failed" | "interrupted";

/**
 * What a tool card knows about one call: its row, its result so far, and the session's subagents (a `task` card shows
 * their live status); the rest is derived from those once.
 */
export interface ToolData {
  readonly row: ToolRow;
  readonly result?: ToolResultItem;
  readonly subagents: readonly Subagent[];
  readonly name: string;
  /** Arguments: the call's (complete once its message ended), else the ones `tool_execution_start` carried. */
  readonly args: JsonObject;
  /** The harness intent (`i`). */
  readonly intent?: string;
  readonly details: unknown;
  /** Result text so far. */
  readonly text: string;
  readonly isError: boolean;
  readonly images: readonly ImageBlock[];
  readonly status: ToolStatus;
  readonly kind: ToolKind;
}

export function toolData(fields: {
  row: ToolRow;
  result?: ToolResultItem;
  subagents: readonly Subagent[];
}): ToolData {
  const { row, result, subagents } = fields;
  const callArgs = row.call?.arguments;
  const args =
    callArgs !== undefined && Object.keys(callArgs).length > 0 ? callArgs : isJsonObject(result?.args) ? result.args : {};
  const intent = row.call?.intent ?? result?.intent ?? str(args.i);
  const isError = result?.isError ?? false;
  const details = result?.details;
  return {
    row,
    result,
    subagents,
    name: row.toolName,
    args,
    intent,
    details,
    text: result === undefined ? "" : textOf(result.content),
    isError,
    images: result?.content.filter(isImageBlock) ?? [],
    status: toolStatus(row, result, isError),
    kind: toolKindFor(row.toolName, { args, details }),
  };
}

function toolStatus(row: ToolRow, result: ToolResultItem | undefined, isError: boolean): ToolStatus {
  switch (result?.state) {
    case undefined:
      return toolRowAbandoned(row) ? "interrupted" : "pending";
    case "running":
      return "running";
    case "background":
      return "background";
    case "interrupted":
      return "interrupted";
    case "done":
      return isError ? "failed" : "done";
  }
}

/** Lines of `text` without a trailing empty line. */
export function linesOf(text: string): string[] {
  const lines = text.split("\n");
  if (lines.length > 1 && lines[lines.length - 1] === "") lines.pop();
  return lines;
}

function str(value: unknown): string | undefined {
  return typeof value === "string" ? value : undefined;
}

function obj(value: unknown): JsonObject | undefined {
  return isJsonObject(value) ? value : undefined;
}

function list(value: unknown): readonly unknown[] {
  return Array.isArray(value) ? value : [];
}

function objects(value: unknown): JsonObject[] {
  return list(value).filter(isJsonObject);
}

function int(value: unknown): number | undefined {
  return typeof value === "number" ? Math.trunc(value) : undefined;
}

function defined<T>(value: T | undefined): value is T {
  return value !== undefined;
}

/** `text` up to its first line break, with ` …` when there is more. */
export function firstLine(text: string): string {
  const newline = text.indexOf("\n");
  return newline === -1 ? text : `${text.slice(0, newline)} …`;
}

/** `parse` run once per ToolData, as Dart's `late final` fields: a card's line and its open body read the same call. */
function once<T>(parse: (data: ToolData) => T): (data: ToolData) => T {
  const parsed = new WeakMap<ToolData, T>();
  return (data) => {
    if (parsed.has(data)) return parsed.get(data) as T;
    const value = parse(data);
    parsed.set(data, value);
    return value;
  };
}

/**
 * Footers omp appends to tool output for the model (`tui/src/tools/bash.ts`, `output-meta.ts`); the card shows the
 * same facts in its header.
 */
const notices = [/^Command exited with code -?\d+$/gm, /^Backgrounded as job .*$/gm];

/** The footer only `bash` appends. */
const wallTimeNotice = /^Wall time: [\d.]+ seconds?$/gm;

/** `text` without the last of each footer, the wall-time one only when `wallTime`. */
export function withoutNotices(text: string, options: { wallTime?: boolean } = {}): string {
  let out = text;
  for (const notice of options.wallTime ? [wallTimeNotice, ...notices] : notices) {
    const last = Array.from(out.matchAll(notice)).pop();
    if (last?.index === undefined) continue;
    out = out.slice(0, last.index) + out.slice(last.index + last[0].length);
  }
  return out.trimEnd();
}

export interface BashCall {
  readonly command: string;
  readonly exitCode?: number;
  readonly timedOut: boolean;
  readonly wallMs?: number;
  /** The output without the footers omp appended. */
  readonly output: string;
  /** A thrown error replaced the output with its message; a failing command keeps its own output. */
  readonly thrown: boolean;
}

export const bashCall = once((data): BashCall => {
  const details = obj(data.details);
  const exitCode = int(details?.exitCode);
  const timedOut = details?.timedOut === true;
  const wall = details?.wallTimeMs;
  return {
    command: str(data.args.command) ?? "",
    exitCode,
    timedOut,
    wallMs: typeof wall === "number" ? wall : undefined,
    // omp 18.10.3 appends the footer only to runs of a second or more and says so in `wallTimeNoticeEmitted`; older
    // omp appends it to every run and has no such field.
    output: withoutNotices(data.text, { wallTime: details?.wallTimeNoticeEmitted !== false }),
    thrown: data.isError && exitCode === undefined && !timedOut,
  };
});

const selector = /:(?:raw|img|conflicts|-?\d[\d,+-]*)$/;

/** A read path without its selector (`:50-100`, `:raw`, `:img`, `:conflicts`, `:-20`, comma lists). */
export function withoutSelector(path: string): string {
  let out = path;
  for (;;) {
    const match = selector.exec(out);
    if (match === null || match.index === 0) return out;
    out = out.slice(0, match.index);
  }
}

/** Extensions of the image files omp reads as images (`read` of a PNG, JPEG, GIF, WebP, …). */
const imageExtensions: Record<string, true> = {
  png: true,
  jpg: true,
  jpeg: true,
  gif: true,
  webp: true,
  bmp: true,
  tif: true,
  tiff: true,
  heic: true,
  heif: true,
  avif: true,
};

/** `PNG` for `image/png`. */
export function imageType(mimeType: string): string {
  return (mimeType.split("/").pop() ?? "").split(/[+;]/)[0]?.toUpperCase() ?? "";
}

export interface ReadCall {
  readonly path: string;
  /** The file behind the read: omp's resolved or source path when it reports one. */
  readonly target: string;
  /** The text omp showed, when it showed text. */
  readonly text?: string;
  readonly lines: readonly string[];
  /** Gutter numbers, one per line; undefined for an elided line. */
  readonly gutter: readonly (number | undefined)[];
  readonly startLine: number;
  /** The first and last line number shown, when lines are. */
  readonly range?: { readonly from: number; readonly to: number };
  readonly totalLines?: number;
  /**
   * omp sends a read image only to a model that takes images; for another it sends the image's metadata as text, and
   * the card shows the file from the machine instead.
   */
  readonly fromMachine: boolean;
  /** What the model got, which omp may have converted (a PNG arrives as WebP): the file's own facts are in Files. */
  readonly pixels?: ImageSize;
}

export const readCall = once((data): ReadCall => {
  const path = str(data.args.path) ?? str(data.args.file_path) ?? "";
  const details = obj(data.details);
  const display = obj(details?.displayContent);
  const text = str(display?.text);
  const startLine = int(display?.startLine) ?? 1;
  const lines = text === undefined ? [] : linesOf(text);
  const numbers = list(display?.lineNumbers).map(int);
  const gutter = numbers.length === lines.length ? numbers : lines.map((_, index) => startLine + index);
  const shown = gutter.filter(defined);
  const first = shown[0];
  const last = shown[shown.length - 1];
  const target = readTarget(details, path);
  const image = data.images[0];
  return {
    path,
    target,
    text,
    lines,
    gutter,
    startLine,
    range: first === undefined || last === undefined ? undefined : { from: first, to: last },
    totalLines: int(details?.totalLines),
    fromMachine:
      data.images.length === 0 &&
      text === undefined &&
      data.status === "done" &&
      imageExtensions[extensionOf(withoutSelector(target))] === true,
    pixels: image?.kind === "InlineImageBlock" ? imageSize(image) : undefined,
  };
});

function readTarget(details: JsonObject | undefined, path: string): string {
  const resolved = str(details?.resolvedPath);
  if (resolved !== undefined) return resolved;
  const source = obj(obj(details?.meta)?.source);
  const value = str(source?.value);
  return source?.type === "path" && value !== undefined ? value : withoutSelector(path);
}

export interface FetchCall {
  readonly url: string;
  readonly finalUrl?: string;
  readonly contentType?: string;
  /** The page without the header block omp puts before it. */
  readonly page: string;
}

export const fetchCall = once((data): FetchCall => {
  const details = obj(data.details);
  // The read output is a header block, a `---` rule, then the page (`buildUrlReadOutput`, `tools/fetch.ts`).
  const separator = data.text.indexOf("\n---\n");
  return {
    url: str(details?.url) ?? str(data.args.url) ?? str(data.args.path) ?? "",
    finalUrl: str(details?.finalUrl),
    contentType: str(details?.contentType),
    page: (separator === -1 ? data.text : data.text.slice(separator + 5)).trim(),
  };
});

/** Whether `url` names its scheme, so it can be opened (Dart's `Uri.hasScheme`). */
export function hasScheme(url: string): boolean {
  return /^[a-z][a-z\d+.-]*:/i.test(url);
}

/** The host of `url`, empty when it has none. */
export function hostOf(url: string): string {
  return /^[a-z][a-z\d+.-]*:\/\/(?:[^@/?#]*@)?(\[[^\]]*\]|[^:/?#]*)/i.exec(url)?.[1]?.toLowerCase() ?? "";
}

const hashlineHeader = /^\[([^\]#\n]+)#[0-9A-Za-z]+\]/m;
const patchHeader = /^\*\*\* (?:Add|Update|Delete) File: (.+)$/m;

/** One file of an edit result: its path, diff and what happened to it. */
export interface EditFile {
  readonly path?: string;
  readonly rows: readonly DiffLine[];
  readonly op?: string;
  readonly move?: string;
  readonly line?: number;
  readonly error?: string;
}

export interface EditCall {
  /** The path the call names: a plain argument, or the first file of a hashline or apply_patch input. */
  readonly path: string;
  /** The first file the result names, which the subject opens. */
  readonly target?: string;
  readonly files: readonly EditFile[];
  readonly added: number;
  readonly removed: number;
  readonly diagnostics: readonly string[];
  /** The hashline or patch input. */
  readonly input?: string;
}

function editFile(file: JsonObject): EditFile {
  return {
    path: str(file.path),
    rows: parseOmpDiff(str(file.diff) ?? ""),
    op: str(file.op),
    move: str(file.move) ?? str(file.rename),
    line: int(file.firstChangedLine),
    error: str(file.displayErrorText) ?? str(file.errorText) ?? str(file.error),
  };
}

function editPath(args: JsonObject): string | undefined {
  const path = str(args.path) ?? str(args.file_path);
  if (path !== undefined) return path;
  const input = str(args.input) ?? str(args.patch) ?? "";
  return (hashlineHeader.exec(input) ?? patchHeader.exec(input))?.[1]?.trim();
}

export const editCall = once((data): EditCall => {
  const details = obj(data.details);
  const files = objects(details?.perFileResults).map(editFile);
  if (files.length === 0 && details !== undefined && typeof details.diff === "string") files.push(editFile(details));
  // While the arguments stream, omp previews the edit (`tool_stream_update`, an `EditPreviewBatch`).
  const shown = files.length > 0 ? files : objects(obj(data.result?.streamUpdate)?.files).map(editFile);
  let added = 0;
  let removed = 0;
  for (const file of shown) {
    for (const row of file.rows) {
      if (row.kind === "added") added++;
      if (row.kind === "removed") removed++;
    }
  }
  return {
    path: editPath(data.args) ?? shown[0]?.path ?? "",
    target: shown[0]?.path,
    files: shown,
    added,
    removed,
    diagnostics: diagnosticsOf(details),
    input: str(data.args.input) ?? str(data.args.patch),
  };
});

function diagnosticsOf(details: JsonObject | undefined): string[] {
  return list(obj(details?.diagnostics)?.messages).filter((message) => typeof message === "string");
}

export interface WriteCall {
  readonly path: string;
  /** The file the subject opens: omp's resolved path when it reports one. */
  readonly target: string;
  readonly content: string;
  readonly lines: readonly string[];
  readonly diagnostics: readonly string[];
}

export const writeCall = once((data): WriteCall => {
  const path = str(data.args.path) ?? str(data.args.file_path) ?? "";
  const content = str(data.args.content) ?? "";
  const details = obj(data.details);
  return {
    path,
    target: str(details?.resolvedPath) ?? path,
    content,
    lines: linesOf(content),
    diagnostics: diagnosticsOf(details),
  };
});

/** A todo task as omp's `todo` details carry it (`TodoItem`, `tui/src/tools/todo.ts`). */
export interface Todo {
  readonly content: string;
  readonly status: TodoStatus;
  readonly blocker?: string;
}

export interface TodoCall {
  readonly phases: readonly { readonly name: string; readonly tasks: readonly Todo[] }[];
  readonly done: number;
  readonly total: number;
  readonly op: string;
  readonly subject: string;
}

function todoStatus(status: string | undefined): TodoStatus {
  switch (status) {
    case "in_progress":
      return "inProgress";
    case "completed":
      return "completed";
    case "abandoned":
    case "dropped":
      return "abandoned";
    case "blocked":
      return "blocked";
    default:
      return "pending";
  }
}

function plannedTasks(items: unknown): Todo[] {
  return list(items)
    .filter((item) => typeof item === "string")
    .map((content) => ({ content, status: "pending" }));
}

export const todoCall = once((data): TodoCall => {
  const details = obj(data.details);
  let phases = objects(details?.phases).map((phase) => ({
    name: str(phase.name) ?? "",
    tasks: objects(phase.tasks).map(
      (task): Todo => ({
        content: str(task.content) ?? "",
        status: todoStatus(str(task.status)),
        blocker: str(task.blocker),
      }),
    ),
  }));
  if (phases.length === 0) {
    // No result yet: the planned list from the arguments.
    phases = objects(data.args.list).map((phase) => ({ name: str(phase.phase) ?? "", tasks: plannedTasks(phase.items) }));
    if (list(data.args.items).length > 0) {
      phases.push({ name: str(data.args.phase) ?? "", tasks: plannedTasks(data.args.items) });
    }
  }
  const tasks = phases.flatMap((phase) => phase.tasks);
  const op = str(details?.op) ?? str(data.args.op) ?? "";
  const named = str(data.args.task) ?? str(data.args.phase);
  return {
    phases,
    done: tasks.filter((task) => task.status === "completed").length,
    total: tasks.length,
    op,
    subject: [op, ...(named === undefined ? [] : [named])].filter((part) => part !== "").join(" · "),
  };
});

/** One subagent of a `task` call: from the live subagent list, the call's progress, its results, or its arguments. */
export interface TaskAgent {
  readonly id: string;
  readonly agent: string;
  readonly status: SubagentStatus;
  readonly task: string;
  readonly activity?: string;
  readonly tokens?: number;
  readonly durationMs?: number;
}

function subagentStatus(status: string | undefined): SubagentStatus {
  switch (status) {
    case "running":
    case "completed":
    case "failed":
    case "aborted":
      return status;
    default:
      return "pending";
  }
}

function resultStatus(result: JsonObject): SubagentStatus {
  if (result.aborted === true) return "aborted";
  if (typeof result.error === "string") return "failed";
  return int(result.exitCode) === 0 ? "completed" : "failed";
}

export const taskAgents = once((data): readonly TaskAgent[] => {
  const details = obj(data.details);
  const live = new Map(data.subagents.map((subagent) => [subagent.id, subagent]));
  const progress = objects(details?.progress);
  const results = new Map(objects(details?.results).map((result) => [str(result.id) ?? "", result]));
  const entries = progress.length > 0 ? progress : Array.from(results.values());
  const agents = entries.map((entry): TaskAgent => {
    const id = str(entry.id) ?? "";
    const subagent = live.get(id);
    const result = results.get(id);
    const progressOf = subagent?.progress;
    const durationMs = int(entry.durationMs);
    return {
      id,
      agent: subagent?.agent ?? str(entry.agent) ?? "",
      status:
        subagent?.status ?? (result === undefined ? subagentStatus(str(entry.status)) : resultStatus(result)),
      task:
        subagent?.description ??
        str(entry.description) ??
        subagent?.assignment ??
        str(entry.assignment) ??
        str(entry.task) ??
        "",
      activity: progressOf?.lastIntent ?? progressOf?.currentTool ?? str(entry.lastIntent),
      tokens: progressOf?.tokens ?? int(entry.tokens),
      durationMs: progressOf?.durationMs ?? (durationMs !== undefined && durationMs > 0 ? durationMs : undefined),
    };
  });
  if (agents.length > 0) return agents;
  // Not started yet: the requested tasks from the arguments (batch or flat form).
  const tasks = list(data.args.tasks).length > 0 ? objects(data.args.tasks) : [data.args];
  return tasks.flatMap((task): TaskAgent[] => {
    const assignment = str(task.task);
    if (assignment === undefined) return [];
    return [{ id: str(task.name) ?? "", agent: str(task.agent) ?? "task", status: "pending", task: assignment }];
  });
});

/**
 * Whether an `ask` call still waits for its answer: until then the question and its options are answered in the
 * request panel under the transcript, and the card is one line.
 */
export function askWaits(data: ToolData): boolean {
  return data.status === "pending" || data.status === "running";
}

/** A question of an `ask` call with its answer (`QuestionResult`, `tui/src/tools/ask.ts`). */
export interface AskQuestion {
  readonly question: string;
  readonly header?: string;
  readonly options: readonly { readonly label: string; readonly description?: string }[];
  /** Index of the recommended option. */
  readonly recommended?: number;
  readonly selected: readonly string[];
  readonly custom?: string;
  readonly note?: string;
  readonly timedOut: boolean;
  readonly answered: boolean;
}

export const askQuestions = once((data): readonly AskQuestion[] => {
  const details = obj(data.details);
  const results = objects(details?.results);
  if (details !== undefined && typeof details.question === "string") results.push(details);
  const asked = objects(data.args.questions);
  const questions: AskQuestion[] = [];
  for (let i = 0; i < Math.max(asked.length, results.length); i++) {
    const question = asked[i] ?? {};
    const id = str(question.id);
    const result = results.find((candidate) => id !== undefined && candidate.id === id) ?? results[i];
    const options = list(question.options).flatMap((option) => {
      if (isJsonObject(option)) return [{ label: str(option.label) ?? "", description: str(option.description) }];
      return typeof option === "string" ? [{ label: option }] : [];
    });
    if (options.length === 0) {
      for (const option of list(result?.options)) if (typeof option === "string") options.push({ label: option });
    }
    questions.push({
      question: str(question.question) ?? str(result?.question) ?? "",
      header: str(question.header),
      options,
      recommended: int(question.recommended),
      selected: list(result?.selectedOptions).filter((option) => typeof option === "string"),
      custom: str(result?.customInput),
      note: str(result?.note),
      timedOut: result?.timedOut === true,
      answered: result !== undefined,
    });
  }
  return questions;
});

export interface WebSource {
  readonly url: string;
  readonly title: string;
  readonly snippet?: string;
  readonly host: string;
}

export interface WebSearchCall {
  readonly query: string;
  /** Whether the result carries omp's response, even without an answer or sources. */
  readonly responded: boolean;
  readonly answer?: string;
  readonly sources: readonly WebSource[];
  readonly error?: string;
}

export const webSearchCall = once((data): WebSearchCall => {
  const details = obj(data.details);
  const response = obj(details?.response);
  return {
    query: str(data.args.query) ?? "",
    responded: response !== undefined,
    answer: str(response?.answer),
    sources: objects(response?.sources).map((source) => {
      const url = str(source.url) ?? "";
      return { url, title: str(source.title) ?? url, snippet: str(source.snippet), host: hostOf(url) };
    }),
    error: str(details?.error),
  };
});

function evalLanguage(language: string | undefined): string | undefined {
  switch (language) {
    case "py":
    case "python":
    case "ipython":
      return "python";
    case "js":
    case "javascript":
    case "ts":
    case "typescript":
      return "javascript";
    default:
      return undefined;
  }
}

export interface EvalCell {
  readonly title?: string;
  readonly code: string;
  readonly language?: string;
  readonly output: string;
  readonly error: boolean;
}

export interface EvalCall {
  readonly code: string;
  readonly language?: string;
  readonly title?: string;
  readonly cells: readonly EvalCell[];
  readonly jsonOutputs: readonly unknown[];
  /** Images in the details, which omp also writes to the session file as blob references. */
  readonly images: readonly ImageBlock[];
  /** The output without omp's footers; omp appends no wall-time line to eval. */
  readonly output: string;
}

export const evalCall = once((data): EvalCall => {
  const details = obj(data.details);
  const language = evalLanguage(
    str(data.args.language) ?? str(details?.language) ?? (data.name === "python" ? "python" : undefined),
  );
  return {
    code: str(data.args.code) ?? "",
    language,
    title: str(data.args.title),
    cells: objects(details?.cells).map((cell) => ({
      title: str(cell.title),
      code: str(cell.code) ?? "",
      language: evalLanguage(str(cell.language)) ?? language,
      output: str(cell.output) ?? "",
      error: cell.status === "error",
    })),
    jsonOutputs: list(details?.jsonOutputs),
    images: objects(details?.images)
      .filter((image) => typeof image.data === "string" && typeof image.mimeType === "string")
      .map(decodeImage),
    output: withoutNotices(data.text),
  };
});

/** The `goal` tool (`packages/tui/src/tools/goal.ts`). */
export interface GoalCall {
  readonly op?: string;
  readonly status?: GoalStatus;
  readonly objective?: string;
  readonly tokensUsed?: number;
  readonly tokenBudget?: number;
  readonly secondsUsed: number;
  readonly report?: string;
}

function goalStatus(status: string | undefined): GoalStatus | undefined {
  switch (status) {
    case "active":
    case "paused":
    case "complete":
    case "dropped":
      return status;
    case "budget-limited":
      return "budgetLimited";
    default:
      return undefined;
  }
}

export const goalCall = once((data): GoalCall => {
  const details = obj(data.details);
  const goal = obj(details?.goal);
  return {
    op: str(details?.op) ?? str(data.args.op),
    status: goalStatus(str(goal?.status)),
    objective: str(goal?.objective) ?? str(data.args.objective),
    tokensUsed: int(goal?.tokensUsed),
    tokenBudget: int(goal?.tokenBudget),
    secondsUsed: int(goal?.timeUsedSeconds) ?? 0,
    report: str(details?.completionBudgetReport),
  };
});

/** The companion's `html_render` tool: a page the reader sees where the call sits. */
export interface PageCall {
  /** As far as it has arrived while the call streams. */
  readonly title: string;
  /** What the reader sees: the page as the tool changed it (local images inlined), else the call's own. */
  readonly html: string;
}

export const pageCall = once((data): PageCall => {
  const details = obj(data.details);
  return {
    title: (str(details?.title) ?? str(data.args.title) ?? "").trim(),
    html: str(details?.html) ?? str(data.args.html) ?? "",
  };
});

/**
 * `Writing page · 12 KB`: the placeholder's line while the call's page streams. The size counts characters, the unit
 * of the tool's limit.
 */
export function pageWriting(data: ToolData): string {
  return t.transcript.page.writing({ size: formatBytes(str(data.args.html)?.length ?? 0) });
}

/** Characters no platform's file names take, and control characters. */
const unsafeFileName = /[\\/:*?"<>|\u0000-\u001f\u007f]+/g;

/**
 * `<title>.html`, what the save panel offers for a page: the title without the characters a file name cannot hold, at
 * most 100 characters before the extension.
 */
export function pageFileName(title: string): string {
  const base = title.replace(unsafeFileName, " ").replace(/\s+/g, " ").trim().replace(/^\.+|\.+$/g, "").slice(0, 100);
  return `${base.trim() || t.transcript.page.fileName}.html`;
}

export interface GenericCall {
  readonly subject: string;
  /** The arguments without the harness intent. */
  readonly arguments: JsonObject;
  readonly output: string;
}

export const genericCall = once((data): GenericCall => {
  let args = data.args;
  let subject = "";
  const path = str(args.path);
  if (data.name === "write" && path?.startsWith("xd://")) {
    // An xd:// device call: the device's own arguments travel as JSON in `content`.
    subject = path;
    const content = str(args.content);
    if (content !== undefined) args = jsonObject(content) ?? args;
  } else {
    for (const [key, value] of Object.entries(args)) {
      if (key !== "i" && typeof value === "string" && value !== "") {
        subject = firstLine(value);
        break;
      }
    }
  }
  const { i: _intent, ...rest } = args;
  return { subject, arguments: rest, output: withoutNotices(data.text) };
});

/** `text` decoded as a JSON object, or undefined when it is not one. */
function jsonObject(text: string): JsonObject | undefined {
  try {
    return obj(JSON.parse(text));
  } catch (error) {
    if (error instanceof SyntaxError) return undefined;
    throw error;
  }
}
