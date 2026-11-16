// Port of the model part of lib/screens/dock/tree/session_tree.dart.
/**
 * The session tree of RPC `get_tree` (`SessionTreeNode[]`, `session/session-entries.ts`), decoded once and flattened
 * into rows the way omp's `/tree` selector shows it (`tui/src/overlays/tree-selector.ts`).
 */
import { describeJson, FormatException, isJsonObject, type JsonObject } from "../../../../core/rpc/json_fields";

/** What an entry is, for its icon and prefix. */
export type TreeEntryKind =
  | "user"
  | "assistant"
  | "toolResult"
  | "bash"
  | "python"
  | "custom"
  | "advisor"
  | "compaction"
  | "branchSummary"
  | "modelChange"
  | "thinkingChange"
  | "label"
  | "other";

/** The `/tree` selector's filter modes. */
export type TreeFilter = "standard" | "noTools" | "userOnly" | "labeledOnly" | "all";

export const treeFilters: readonly TreeFilter[] = ["standard", "noTools", "userOnly", "labeledOnly", "all"];

/** One session entry, reduced to what a tree row shows. */
export interface TreeEntry {
  readonly id: string;
  /** The entry's `type` (`message`, `compaction`, `title_change`, …). */
  readonly type: string;
  readonly kind: TreeEntryKind;
  /** One line: the message text, a tool call summary, or the entry's own value (model, summary, title). */
  readonly text: string;
  /** The user's bookmark on this entry (`tree.label`). */
  readonly label?: string;
  /** Epoch milliseconds. */
  readonly timestamp?: number;
  /** Context size before a compaction. */
  readonly tokensBefore?: number;
  /**
   * Advisor names (other than `default`) and severities of an `advisor` entry, comma-separated, as omp's
   * `advisorTreeDisplay` lists them; `text` holds the notes.
   */
  readonly advisorTags: string;
  /** A prompt the user typed (or a user-invoked skill): what `/branch` and the rewind start from. */
  readonly userRequest: boolean;
  /** Settings and bookkeeping entries (model, thinking, labels, titles, …), hidden unless the filter is `all`. */
  readonly bookkeeping: boolean;
  /** An assistant message with tool calls only; the tree hides it unless it is the current leaf. */
  readonly bareToolCalls: boolean;
  /** An assistant message the user aborted before it said anything. */
  readonly aborted: boolean;
  /** An assistant message that failed; `text` holds the error. */
  readonly error: boolean;
}

/** One visible row of the tree. */
export interface TreeRow {
  readonly entry: TreeEntry;
  /** Indentation level. It grows only at branch points; a linear chain keeps its branch head's depth. */
  readonly depth: number;
  /** The first entry of one of several branches from the same point; it can be collapsed. */
  readonly branchHead: boolean;
  /** The last of its sibling branches. */
  readonly lastSibling: boolean;
  /** Set when this branch head is collapsed: how many visible entries it hides. */
  readonly collapsedCount?: number;
  /** On the path from the root to the current leaf. */
  readonly onActivePath: boolean;
  /** The current position: the session's leaf, or its nearest visible ancestor when the filter hides the leaf. */
  readonly isLeaf: boolean;
}

/** The decoded tree: entries in pre-order with their parent and child indexes. */
export interface SessionTree {
  /** Every entry, parents before children. */
  readonly entries: readonly TreeEntry[];
  /** Per entry: its parent's index, -1 for a root. */
  readonly parents: readonly number[];
  readonly children: readonly (readonly number[])[];
  readonly roots: readonly number[];
  /** The current leaf; undefined for an empty branch. */
  readonly leafId?: string;
  /** Per entry: on the path from the root to `leafId`. */
  readonly active: readonly boolean[];
}

/**
 * Decodes a `get_tree` result. Throws FormatException when a node is malformed. Deep trees decode without recursion:
 * a long linear session nests one level per entry.
 */
export function sessionTreeDecode(forest: readonly JsonObject[], leafId: string | undefined): SessionTree {
  const nodes: JsonObject[] = [];
  const parents: number[] = [];
  const stack: [JsonObject, number][] = forest.map((node): [JsonObject, number] => [node, -1]).reverse();
  for (let visit = stack.pop(); visit !== undefined; visit = stack.pop()) {
    const [node, parent] = visit;
    const index = nodes.length;
    nodes.push(node);
    parents.push(parent);
    const children = node.children ?? [];
    if (!Array.isArray(children)) {
      throw new FormatException(`tree node children: expected an array, got ${describeJson(children)}`);
    }
    for (let k = children.length - 1; k >= 0; k--) {
      const child: unknown = children[k];
      if (!isJsonObject(child)) throw new FormatException("tree node child: expected an object");
      stack.push([child, index]);
    }
  }

  const toolCalls = new Map<string, ToolCall>();
  for (const node of nodes) {
    const entry = node.entry;
    if (!isJsonObject(entry) || entry.type !== "message") continue;
    const message = entry.message;
    if (!isJsonObject(message) || message.role !== "assistant" || !Array.isArray(message.content)) continue;
    for (const block of message.content) {
      if (!isJsonObject(block) || block.type !== "toolCall") continue;
      if (typeof block.id !== "string" || typeof block.name !== "string") continue;
      toolCalls.set(block.id, { name: block.name, arguments: isJsonObject(block.arguments) ? block.arguments : {} });
    }
  }

  const entries = nodes.map((node) => decodeNode(node, toolCalls));
  const children: number[][] = nodes.map(() => []);
  const roots: number[] = [];
  for (let i = 0; i < nodes.length; i++) {
    const parent = parents[i]!;
    if (parent < 0) {
      roots.push(i);
    } else {
      children[parent]!.push(i);
    }
  }

  const active = nodes.map(() => false);
  if (leafId !== undefined) {
    let index = entries.findIndex((entry) => entry.id === leafId);
    while (index >= 0) {
      active[index] = true;
      index = parents[index]!;
    }
  }
  return { entries, parents, children, roots, leafId, active };
}

/** The entry `id`'s parent id, or undefined for a root or an unknown id. */
export function sessionTreeParentOf(tree: SessionTree, id: string): string | undefined {
  const index = tree.entries.findIndex((entry) => entry.id === id);
  const parent = index < 0 ? -1 : tree.parents[index]!;
  return parent < 0 ? undefined : tree.entries[parent]!.id;
}

/**
 * The visible rows. Entries `filter` or `query` hide lift their visible descendants to the nearest visible ancestor. A
 * branch head is expanded when it holds the current leaf, flipped by `toggled` (branch head ids); a non-empty `query`
 * expands every branch. As in omp's selector, a hidden leaf (often a bookkeeping entry such as `session_exit`) marks
 * its nearest visible ancestor as the current position.
 */
export function sessionTreeRows(
  tree: SessionTree,
  options: { filter?: TreeFilter; query?: string; toggled?: ReadonlySet<string> } = {},
): TreeRow[] {
  const { filter = "standard", query = "", toggled = new Set<string>() } = options;
  const { entries, parents, active, leafId } = tree;
  const count = entries.length;
  const tokens = query
    .toLowerCase()
    .split(/\s+/)
    .filter((token) => token.length > 0);
  const visible = entries.map((entry) => isVisible(entry, leafId, filter, tokens));
  let current = leafId === undefined ? -1 : entries.findIndex((entry) => entry.id === leafId);
  while (current >= 0 && !visible[current]) {
    current = parents[current]!;
  }

  // Children before parents: the reverse of pre-order.
  const display: number[][] = new Array<number[]>(count);
  const lifted: number[][] = new Array<number[]>(count);
  const hidden: number[] = new Array<number>(count).fill(0);
  for (let i = count - 1; i >= 0; i--) {
    const shown: number[] = [];
    for (const child of ordered(tree, tree.children[i]!)) {
      for (const index of lifted[child]!) shown.push(index);
    }
    display[i] = shown;
    let size = 0;
    for (const child of shown) {
      size += 1 + hidden[child]!;
    }
    hidden[i] = size;
    lifted[i] = visible[i] ? [i] : shown;
  }

  // Several first entries (the first message was replaced, or a hidden root holds several) are branches too, one
  // level in, so an abandoned one cannot read as the continuation of the current one.
  const roots = ordered(tree, tree.roots).flatMap((root) => lifted[root]!);
  const rows: TreeRow[] = [];
  const branched = roots.length > 1;
  const stack: Visit[] = [];
  for (let k = roots.length - 1; k >= 0; k--) {
    stack.push({
      index: roots[k]!,
      depth: branched ? 1 : 0,
      branchHead: branched,
      lastSibling: branched && k === roots.length - 1,
    });
  }
  for (let visit = stack.pop(); visit !== undefined; visit = stack.pop()) {
    const entry = entries[visit.index]!;
    const expanded = !visit.branchHead || tokens.length > 0 || active[visit.index] !== toggled.has(entry.id);
    const kids = display[visit.index]!;
    rows.push({
      entry,
      depth: visit.depth,
      branchHead: visit.branchHead,
      lastSibling: visit.lastSibling,
      collapsedCount: expanded || kids.length === 0 ? undefined : hidden[visit.index],
      onActivePath: active[visit.index]!,
      isLeaf: visit.index === current,
    });
    if (!expanded) continue;
    if (kids.length === 1) {
      stack.push({ index: kids[0]!, depth: visit.depth, branchHead: false, lastSibling: false });
    } else {
      for (let k = kids.length - 1; k >= 0; k--) {
        stack.push({ index: kids[k]!, depth: visit.depth + 1, branchHead: true, lastSibling: k === kids.length - 1 });
      }
    }
  }
  return rows;
}

/** The branch holding the current leaf first; otherwise the order omp appended them. */
function ordered(tree: SessionTree, indexes: readonly number[]): readonly number[] {
  const active = indexes.findIndex((index) => tree.active[index]);
  if (active <= 0) return indexes;
  return [indexes[active]!, ...indexes.slice(0, active), ...indexes.slice(active + 1)];
}

function isVisible(
  entry: TreeEntry,
  leafId: string | undefined,
  filter: TreeFilter,
  tokens: readonly string[],
): boolean {
  // The selector keeps the leaf visible even when it only called tools, so the position shows.
  if (entry.bareToolCalls && entry.id !== leafId) return false;
  const passes = {
    standard: !entry.bookkeeping,
    noTools: !entry.bookkeeping && entry.kind !== "toolResult",
    userOnly: entry.userRequest,
    labeledOnly: entry.label !== undefined,
    all: true,
  }[filter];
  if (!passes || tokens.length === 0) return passes;
  const haystack = `${entry.label ?? ""} ${entry.advisorTags} ${entry.text}`.toLowerCase();
  return tokens.every((token) => haystack.includes(token));
}

interface Visit {
  readonly index: number;
  readonly depth: number;
  readonly branchHead: boolean;
  readonly lastSibling: boolean;
}

interface ToolCall {
  readonly name: string;
  readonly arguments: JsonObject;
}

/** Longest preview kept per entry; rows show one line anyway. */
const textLimit = 400;

/** Bookkeeping entry types the `/tree` selector hides by default (`isSettingsEntry`). */
const bookkeepingTypes = new Set([
  "label",
  "custom",
  "model_change",
  "model_usage",
  "thinking_level_change",
  "service_tier_change",
  "title_change",
  "credential_pin",
  "session_init",
  "ttsr_injection",
  "mode_change",
  "reset_boundary",
]);

const stringOr = (value: unknown, fallback: string): string => (typeof value === "string" ? value : fallback);

function decodeNode(node: JsonObject, toolCalls: ReadonlyMap<string, ToolCall>): TreeEntry {
  const entry = node.entry;
  if (!isJsonObject(entry)) throw new FormatException('tree node: missing "entry" object');
  const { id, type } = entry;
  if (typeof id !== "string" || typeof type !== "string") {
    throw new FormatException('tree entry: missing "id" or "type"');
  }
  const label = typeof node.label === "string" ? node.label : undefined;
  const timestamp = parseTimestamp(entry.timestamp);
  const bookkeeping = bookkeepingTypes.has(type);

  const make = (
    kind: TreeEntryKind,
    text: string,
    fields: { userRequest?: boolean; tokensBefore?: number; advisorTags?: string } = {},
  ): TreeEntry => ({
    id,
    type,
    kind,
    text: oneLine(text),
    label,
    timestamp,
    tokensBefore: fields.tokensBefore,
    advisorTags: fields.advisorTags ?? "",
    userRequest: fields.userRequest ?? false,
    bookkeeping,
    bareToolCalls: false,
    aborted: false,
    error: false,
  });

  switch (type) {
    case "message": {
      const message = entry.message;
      if (!isJsonObject(message)) throw new FormatException(`tree entry ${id}: missing "message" object`);
      return decodeMessage(id, message, label, timestamp, toolCalls);
    }
    case "custom_message": {
      const customType = stringOr(entry.customType, "");
      const text = joinText(entry.content);
      if (customType === "advisor") {
        const { tags, notes } = advisorNotes(entry.details);
        return make("advisor", notes, { advisorTags: tags });
      }
      return make("custom", `[${customType}]: ${text.replace(systemTag, "")}`, {
        userRequest: entry.attribution === "user",
      });
    }
    case "compaction": {
      const summary = entry.shortSummary ?? entry.summary;
      const tokens = entry.tokensBefore;
      return make("compaction", stringOr(summary, ""), {
        tokensBefore: typeof tokens === "number" ? Math.round(tokens) : undefined,
      });
    }
    case "branch_summary":
      return make("branchSummary", stringOr(entry.summary, ""));
    case "model_change":
      return make("modelChange", stringOr(entry.model, ""));
    case "thinking_level_change":
      return make("thinkingChange", stringOr(entry.thinkingLevel, "off"));
    case "label":
      return make("label", stringOr(entry.label, ""));
    case "title_change":
      return make("other", stringOr(entry.title, ""));
    case "mode_change":
      return make("other", stringOr(entry.mode, ""));
    case "custom":
      return make("other", stringOr(entry.customType, ""));
    case "credential_pin":
      return make("other", stringOr(entry.provider, ""));
    case "model_usage": {
      const provider = stringOr(entry.provider, "");
      const model = stringOr(entry.model, "");
      const purpose = stringOr(entry.purpose, "");
      return make("other", `${purpose} ${provider}/${model}`);
    }
    default:
      return make("other", "");
  }
}

function decodeMessage(
  id: string,
  message: JsonObject,
  label: string | undefined,
  timestamp: number | undefined,
  toolCalls: ReadonlyMap<string, ToolCall>,
): TreeEntry {
  const role = message.role;
  const make = (
    kind: TreeEntryKind,
    text: string,
    flags: { userRequest?: boolean; bareToolCalls?: boolean; aborted?: boolean; error?: boolean } = {},
  ): TreeEntry => ({
    id,
    type: "message",
    kind,
    text: oneLine(text),
    label,
    timestamp,
    advisorTags: "",
    userRequest: flags.userRequest ?? false,
    bookkeeping: false,
    bareToolCalls: flags.bareToolCalls ?? false,
    aborted: flags.aborted ?? false,
    error: flags.error ?? false,
  });

  switch (role) {
    case "user":
      return make("user", joinText(message.content), { userRequest: true });
    case "assistant": {
      const text = joinText(message.content);
      if (hasText(text)) return make("assistant", text);
      const stopReason = message.stopReason ?? undefined;
      const errorMessage = message.errorMessage;
      if (typeof errorMessage === "string" && errorMessage.length > 0) {
        return make("assistant", errorMessage, { error: true });
      }
      if (stopReason === "aborted") return make("assistant", "", { aborted: true });
      // `stop` and `toolUse` without text: a turn that only called tools.
      const quiet = stopReason === undefined || stopReason === "stop" || stopReason === "toolUse";
      return make("assistant", "", { bareToolCalls: quiet, error: !quiet });
    }
    case "toolResult": {
      const callId = message.toolCallId;
      const call = typeof callId === "string" ? toolCalls.get(callId) : undefined;
      const toolName = stringOr(message.toolName, "tool");
      return make("toolResult", call === undefined ? toolName : describeToolCall(call));
    }
    case "bashExecution":
      return make("bash", stringOr(message.command, ""));
    case "pythonExecution":
      return make("python", stringOr(message.code, ""));
    case "custom": {
      const customType = stringOr(message.customType, "");
      return make("custom", `[${customType}]: ${joinText(message.content).replace(systemTag, "")}`, {
        userRequest: message.attribution === "user",
      });
    }
    default:
      return make("other", `[${dartString(role)}] ${joinText(message.content)}`);
  }
}

/** The advisor's notes and their tags (`advisorTreeDisplay`, which shows `advisor (<tags>): <notes>`). */
function advisorNotes(details: unknown): { tags: string; notes: string } {
  const notes: string[] = [];
  const advisors: string[] = [];
  const severities: string[] = [];
  if (isJsonObject(details) && Array.isArray(details.notes)) {
    for (const note of details.notes) {
      if (!isJsonObject(note)) continue;
      if (typeof note.note === "string") notes.push(note.note);
      const name = note.advisor;
      if (typeof name === "string" && name.length > 0 && name !== "default" && !advisors.includes(name)) {
        advisors.push(name);
      }
      const severity = note.severity;
      if (typeof severity === "string" && severity.length > 0 && !severities.includes(severity)) {
        severities.push(severity);
      }
    }
  }
  return { tags: [...advisors, ...severities].join(", "), notes: notes.join(" ") };
}

/**
 * A tool call as the `/tree` selector abbreviates it (`#formatToolCall`), without the brackets; a tool the selector
 * dumps the arguments of reads as its harness intent where the call has one.
 */
function describeToolCall(call: ToolCall): string {
  const args = call.arguments;
  const str = (key: string): string => stringOr(args[key], "");
  const scopeOf = (paths: unknown): string => {
    if (typeof paths === "string") return paths;
    if (Array.isArray(paths)) return paths.filter((path) => typeof path === "string").join(", ");
    return ".";
  };
  switch (call.name) {
    case "read": {
      const path = str("path").length > 0 ? str("path") : str("file_path");
      const offset = Number.isInteger(args.offset) ? (args.offset as number) : undefined;
      const limit = Number.isInteger(args.limit) ? (args.limit as number) : undefined;
      if (offset === undefined && limit === undefined) return `read ${path}`;
      const start = offset ?? 1;
      return limit !== undefined ? `read ${path}:${start}-${start + limit - 1}` : `read ${path}:${start}`;
    }
    case "write":
    case "edit":
      return `${call.name} ${str("path").length > 0 ? str("path") : str("file_path")}`;
    case "bash":
      return `bash ${str("command")}`;
    case "grep":
      return `grep /${str("pattern")}/ in ${scopeOf(args.paths ?? args.path)}`;
    case "glob":
      return `glob ${scopeOf(args.path ?? args.paths)}`;
    case "ls":
      return `ls ${str("path").length > 0 ? str("path") : "."}`;
    default:
      // omp's harness intent (`i`) says what the call is for in a line; the arguments' dump is all but unreadable.
      return str("i").trim().length > 0 ? `${call.name} ${str("i").trim()}` : `${call.name} ${compactJson(args)}`;
  }
}

function compactJson(args: JsonObject): string {
  const parts: string[] = [];
  for (const [key, value] of Object.entries(args)) {
    parts.push(`${key}: ${dartString(value)}`);
    if (parts.join(", ").length > 80) break;
  }
  return parts.join(", ");
}

/** A JSON value as Dart's `toString` prints it: strings unquoted, `null`, `[a, b]`, `{key: value}`. */
function dartString(value: unknown): string {
  if (value === undefined || value === null) return "null";
  if (Array.isArray(value)) return `[${value.map(dartString).join(", ")}]`;
  if (isJsonObject(value)) {
    return `{${Object.entries(value)
      .map(([key, item]) => `${key}: ${dartString(item)}`)
      .join(", ")}}`;
  }
  return String(value);
}

/** Text blocks joined, or the string itself. */
function joinText(content: unknown): string {
  if (typeof content === "string") return content;
  if (!Array.isArray(content)) return "";
  let text = "";
  for (const block of content) {
    if (isJsonObject(block) && block.type === "text" && typeof block.text === "string") text += block.text;
  }
  return text;
}

function parseTimestamp(value: unknown): number | undefined {
  if (typeof value !== "string") return undefined;
  const time = Date.parse(value);
  return Number.isNaN(time) ? undefined : time;
}

/** Text beyond dots and whitespace (`canonicalizeMessage`): a lone "..." is no answer. */
const hasText = (text: string): boolean => text.trim().replace(/[.\u2026\s]/g, "").length > 0;

const systemTag = /<\/?system[^>]*>/g;

function oneLine(text: string): string {
  const flat = text.replace(/\s+/g, " ").trim();
  return flat.length <= textLimit ? flat : flat.slice(0, textLimit);
}
