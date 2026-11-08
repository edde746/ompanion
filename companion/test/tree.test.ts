import { expect, test } from "bun:test";
import type { SessionTreeNode } from "@oh-my-pi/pi-coding-agent/session/session-entries";
import { slimTree, type TreeNode, treeStringLimit } from "../src/verbs/session/tree.ts";

/** A tree node; the fixtures carry only the fields under test. */
function node(entry: object, children: SessionTreeNode[] = [], label?: string): SessionTreeNode {
	return { entry, children, ...(label === undefined ? {} : { label }) } as unknown as SessionTreeNode;
}

const long = "x".repeat(treeStringLimit + 500);
const image = { type: "image", data: "iVBORw0K".repeat(1000), mimeType: "image/png" };

test("a tree keeps its shape, labels and what rows show, without tool output, images or thinking", () => {
	const call = { type: "toolCall", id: "c1", name: "bash", arguments: { command: long, env: { A: "1" } }, intent: "run" };
	const tree = [
		node({ type: "session_init", id: "s", parentId: null, timestamp: "t0", data: { big: long } }, [
			node(
				{
					type: "message",
					id: "u",
					parentId: "s",
					message: { role: "user", content: [{ type: "text", text: "question" }, image], timestamp: 1 },
				},
				[
					node(
						{
							type: "message",
							id: "a",
							parentId: "u",
							message: {
								role: "assistant",
								content: [{ type: "thinking", thinking: long }, { type: "text", text: long }, call],
								stopReason: "toolUse",
								usage: { input: 1, output: 2 },
							},
						},
						[
							node({
								type: "message",
								id: "r",
								parentId: "a",
								message: {
									role: "toolResult",
									toolCallId: "c1",
									toolName: "bash",
									content: [{ type: "text", text: long }, image],
									details: { exitCode: 0 },
								},
							}),
						],
						"checkpoint",
					),
					node({
						type: "custom_message",
						id: "adv",
						parentId: "u",
						customType: "advisor",
						content: "notes",
						details: { notes: [{ note: "check the parser", advisor: "security", severity: "high", extra: {} }] },
					}),
				],
			),
		]),
	];

	expect(slimTree(tree)).toEqual([
		{
			entry: { type: "session_init", id: "s", parentId: null, timestamp: "t0" },
			children: [
				{
					entry: {
						type: "message",
						id: "u",
						parentId: "s",
						message: { role: "user", content: [{ type: "text", text: "question" }], timestamp: 1 },
					},
					children: [
						{
							entry: {
								type: "message",
								id: "a",
								parentId: "u",
								message: {
									role: "assistant",
									content: [
										{ type: "text", text: long.slice(0, treeStringLimit) },
										{
											type: "toolCall",
											id: "c1",
											name: "bash",
											arguments: { command: long.slice(0, treeStringLimit), env: { A: "1" } },
											intent: "run",
										},
									],
									stopReason: "toolUse",
								},
							},
							children: [
								{
									entry: {
										type: "message",
										id: "r",
										parentId: "a",
										message: { role: "toolResult", toolCallId: "c1", toolName: "bash" },
									},
									children: [],
								},
							],
							label: "checkpoint",
						},
						{
							entry: {
								type: "custom_message",
								id: "adv",
								parentId: "u",
								customType: "advisor",
								content: "notes",
								details: { notes: [{ note: "check the parser", advisor: "security", severity: "high" }] },
							},
							children: [],
						},
					],
				},
			],
		},
	]);
});

test("a long linear session, one level per entry, is walked without running out of stack", () => {
	const depth = 50_000;
	let tree = node({ type: "message", id: `m${depth - 1}`, message: { role: "user", content: "last" } });
	for (let i = depth - 2; i >= 0; i--) tree = node({ type: "label", id: `m${i}`, label: "l" }, [tree]);

	let level: TreeNode | undefined = slimTree([tree])[0];
	let count = 0;
	let last: TreeNode | undefined;
	for (; level !== undefined; level = level.children[0]) {
		last = level;
		count++;
	}
	expect(count).toBe(depth);
	expect(last?.entry).toEqual({ type: "message", id: `m${depth - 1}`, message: { role: "user", content: "last" } });
});
