import type { SessionTreeNode } from "@oh-my-pi/pi-coding-agent/session/session-entries";
import { isRecord } from "../../args.ts";

/** Longest string `tree.get` keeps: a tree row shows at most 400 characters (the app's `textLimit`). */
export const treeStringLimit = 1024;

/** A `tree.get` node: omp's `SessionTreeNode` with its entry reduced to what a tree row shows. */
export interface TreeNode {
	entry: Record<string, unknown>;
	children: TreeNode[];
	label?: string;
}

/**
 * omp's session tree (`get_tree`) reduced to what the app's tree rows read (docs/contracts/ompx.md, `tree.get`).
 * Returned whole, a tree holds every tool output and image of the session: 30 MB for a 26 MB session file, which runs
 * through `out.jsonl` and rotates it under every attached device (3.6 MB reduced). Walks without recursion: a long
 * linear session nests one level per entry.
 */
export function slimTree(tree: readonly SessionTreeNode[]): TreeNode[] {
	const roots: TreeNode[] = [];
	const stack: { node: SessionTreeNode; siblings: TreeNode[] }[] = [];
	for (let i = tree.length - 1; i >= 0; i--) stack.push({ node: tree[i]!, siblings: roots });
	for (let visit = stack.pop(); visit !== undefined; visit = stack.pop()) {
		const { node, siblings } = visit;
		const slim: TreeNode = { entry: slimEntry(node.entry), children: [] };
		if (node.label !== undefined) slim.label = node.label;
		siblings.push(slim);
		for (let i = node.children.length - 1; i >= 0; i--) {
			stack.push({ node: node.children[i]!, siblings: slim.children });
		}
	}
	return roots;
}

function slimEntry(entry: object): Record<string, unknown> {
	const slim = scalars(entry);
	if (!("type" in entry)) return slim;
	if (entry.type === "message" && "message" in entry && isRecord(entry.message)) {
		const message = entry.message;
		const kept = scalars(message);
		// A tool result's row shows its call; its content (file reads, command output, images) is most of a session.
		if (message.role !== "toolResult" && message.content !== undefined) kept.content = slimContent(message.content);
		slim.message = kept;
	} else if (entry.type === "custom_message") {
		if ("content" in entry) slim.content = slimContent(entry.content);
		// An advisor's row shows its notes, advisors and severities.
		if ("details" in entry && isRecord(entry.details) && Array.isArray(entry.details.notes)) {
			slim.details = { notes: entry.details.notes.filter(isRecord).map(scalars) };
		}
	}
	return slim;
}

/** A string, or the text and tool call blocks: images and thinking never show in a row. */
function slimContent(content: unknown): unknown {
	if (typeof content === "string") return cut(content);
	if (!Array.isArray(content)) return null;
	const blocks: Record<string, unknown>[] = [];
	for (const block of content) {
		if (!isRecord(block)) continue;
		if (block.type === "text") blocks.push(scalars(block));
		// A row names a tool call by its arguments: a path, a command, its intent, or a dump of them.
		else if (block.type === "toolCall") blocks.push({ ...scalars(block), arguments: cutStrings(block.arguments) });
	}
	return blocks;
}

/** The strings, numbers, booleans and nulls of [value], strings cut to [treeStringLimit]. */
function scalars(value: object): Record<string, unknown> {
	const kept: Record<string, unknown> = {};
	for (const [key, field] of Object.entries(value)) {
		if (typeof field === "string") kept[key] = cut(field);
		else if (typeof field === "number" || typeof field === "boolean" || field === null) kept[key] = field;
	}
	return kept;
}

function cutStrings(value: unknown): unknown {
	if (typeof value === "string") return cut(value);
	if (Array.isArray(value)) return value.map(cutStrings);
	if (!isRecord(value)) return value;
	const kept: Record<string, unknown> = {};
	for (const [key, field] of Object.entries(value)) kept[key] = cutStrings(field);
	return kept;
}

function cut(text: string): string {
	return text.length > treeStringLimit ? text.slice(0, treeStringLimit) : text;
}
