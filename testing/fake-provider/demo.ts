/**
 * The fake provider's `--demo` mode: canned turns for running the app against a real omp without a
 * model. Every request that finds no eligible queued turn is answered from a fixed cycle of scenarios
 * that exercise the transcript renderers, tool cards, todos, thinking and dialogs.
 *
 * The conversation in each request decides the step, so one server serves any number of sessions:
 * - A user prompt (typed text, not only the `<system-…>` blocks omp adds) with no assistant reply after
 *   it starts the next scenario. Prompts, steers and follow-ups all count.
 * - A tool result continues the scenario that made the call: after `read` comes an `edit` quoting the
 *   hashline tag the read returned.
 * - Messages omp injects after an assistant reply get a short answer. A todo reminder, which omp sends
 *   while the demo's tasks are open, is answered by marking every task done, so it comes once a cycle.
 * - Requests without tools are side requests (compaction and other summaries). The demo returns
 *   undefined for them and the server answers "ok", so they never advance the cycle.
 */
import { isRecord } from "../json.ts";
import type { Step, StreamTurn } from "./server.ts";

export interface DemoReply {
	/** The step's name in the request log, e.g. `read` or `edit-answer`. */
	label: string;
	turn: StreamTurn;
}

type Message = Record<string, unknown>;

/** Toggled on the first short line of the README the demo reads, so the file never grows. */
const EDIT_MARK = " (edited by the omp-app demo)";

const MARKDOWN = [
	"# Renderer demo",
	"",
	"This reply exercises the transcript: **bold**, *italic*, ~~struck~~, `inline code` and a link to",
	"[omp on GitHub](https://github.com/can1357/oh-my-pi).",
	"",
	"## Lists",
	"",
	"- Machines",
	"  - this computer",
	"  - SSH through a jump host",
	"- Sessions that survive a dropped connection",
	"",
	"1. Open a session",
	"2. Send a prompt",
	"3. Watch it stream",
	"",
	"- [x] Tables",
	"- [ ] Diagrams",
	"",
	"## Table",
	"",
	"| Surface | Route | State |",
	"|:---|:---:|---:|",
	"| Transcript | RPC events | ready |",
	"| Pause | companion | planned |",
	"| Voice | app | later |",
	"",
	"## Code",
	"",
	"```dart",
	"void main() {",
	"  const machines = ['this computer', 'ssh', 'tailscale'];",
	"  for (final (index, name) in machines.indexed) {",
	"    print('$index: $name');",
	"  }",
	"}",
	"```",
	"",
	"~~~sh",
	"omp --mode rpc-ui --model fake/fake-1",
	"~~~",
	"",
	"## Math",
	"",
	"Inline: $e^{i\\pi} + 1 = 0$ and $\\sum_{k=1}^{n} k = \\frac{n(n+1)}{2}$.",
	"",
	"$$",
	"\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}",
	"$$",
	"",
	"> A quote closes the demo.",
].join("\n");

const SLOW_TOPICS = [
	"the transcript keeps up with a long answer",
	"pause parks the run at its next model call",
	"abort ends this stream and the turn",
	"a steer waits until this answer is done",
	"a follow-up queues behind the steer",
	"every attached device sees the same lines",
	"the stream is 40 lines, 500 ms apart",
	"the next prompt starts the demo over",
];

function call(name: string, args: Record<string, unknown>): Step {
	return { toolCall: { name, arguments: args } };
}

/** One text step per line, `delayMs` apart, so the reply visibly streams. */
function byLine(text: string, delayMs: number): Step[] {
	return text.split(/(?<=\n)/).flatMap((line, i): Step[] => (i === 0 ? [{ text: line }] : [{ delayMs }, { text: line }]));
}

function answer(label: string, text: string): DemoReply {
	return { label, turn: { steps: byLine(text, 40) } };
}

/** The cycle: one scenario per user prompt. */
const SCENARIOS: DemoReply[] = [
	{ label: "markdown", turn: { steps: byLine(MARKDOWN, 40) } },
	{
		label: "bash",
		turn: { steps: [{ text: "Listing the working directory." }, call("bash", { i: "Listing files", command: "ls -la" })] },
	},
	{
		label: "read",
		turn: {
			steps: [{ text: "Reading README.md before changing it." }, call("read", { i: "Reading README.md", path: "README.md" })],
		},
	},
	{
		label: "todo",
		turn: {
			steps: [
				call("todo", {
					i: "Planning the demo",
					op: "init",
					list: [{ phase: "Demo", items: ["Sketch the screen", "Wire the data", "Polish the details"] }],
				}),
			],
		},
	},
	{
		label: "thinking",
		turn: {
			steps: [
				{ thinking: "The user wants to see reasoning. " },
				{ delayMs: 300 },
				{ thinking: "It streams as reasoning_content deltas, " },
				{ delayMs: 300 },
				{ thinking: "which omp shows before the answer." },
				{ delayMs: 300 },
				{ text: "The reasoning above streamed before this answer." },
			],
		},
	},
	{
		label: "ask",
		turn: {
			steps: [
				call("ask", {
					i: "Asking for a choice",
					questions: [
						{
							id: "option",
							question: "Which option should the demo take?",
							options: [{ label: "Option A" }, { label: "Option B" }],
						},
					],
				}),
			],
		},
	},
	{
		label: "slow",
		turn: {
			steps: [
				{ text: "This answer streams for about 20 seconds, long enough to pause, abort or steer it.\n\n" },
				...Array.from({ length: 40 }, (_, i): Step[] => [
					{ delayMs: 500 },
					{ text: `${i + 1}. ${SLOW_TOPICS[i % SLOW_TOPICS.length]}.\n` },
				]).flat(),
				{ text: "\nThat is the end of the slow answer." },
			],
		},
	},
];

/** Text parts of a chat message whose content is a string or a list of parts. */
function texts(message: Message): string[] {
	const { content } = message;
	if (typeof content === "string") return [content];
	if (!Array.isArray(content)) return [];
	return content.flatMap(part => (isRecord(part) && typeof part.text === "string" ? [part.text] : []));
}

/** Name of the tool whose call `id` identifies, from the assistant message that made it. */
function toolName(messages: Message[], id: unknown): string {
	for (const message of messages) {
		if (message.role !== "assistant" || !Array.isArray(message.tool_calls)) continue;
		for (const toolCall of message.tool_calls) {
			if (isRecord(toolCall) && toolCall.id === id && isRecord(toolCall.function) && typeof toolCall.function.name === "string") {
				return toolCall.function.name;
			}
		}
	}
	return "unknown";
}

/** The scenario step that follows a tool result. */
function afterTool(name: string, result: string): DemoReply {
	switch (name) {
		case "bash":
			return answer("bash-answer", "That is the working directory as `ls -la` sees it.");
		case "read": {
			const header = /^\[([^\]#\n]+)#([0-9A-F]{4})\]$/m.exec(result);
			const target = [...result.matchAll(/^(\d+):(.*)$/gm)].find(
				([, , text = ""]) => text.trim() !== "" && text.length <= 200,
			);
			if (!header || !target) {
				return answer("edit-skipped", "There is no readable README.md here, so there is no line to change.");
			}
			const [, file, tag] = header;
			const [, line, text = ""] = target;
			const next = text.endsWith(EDIT_MARK) ? text.slice(0, -EDIT_MARK.length) : `${text}${EDIT_MARK}`;
			return {
				label: "edit",
				turn: {
					steps: [
						{ text: `Toggling the demo marker on line ${line}.` },
						call("edit", { i: "Toggling the demo marker", input: `[${file}#${tag}]\nPUT ${line}.=${line}:\n+${next}` }),
					],
				},
			};
		}
		case "edit":
			return /^\[[^\]\n]+#[0-9A-F]{4}\]/.test(result.trimStart())
				? answer("edit-answer", "Changed one line of README.md; the next round of the demo changes it back.")
				: answer("edit-answer", `The edit failed: ${result.trim().split("\n")[0]}`);
		case "todo":
			return /Remaining items: none/.test(result)
				? answer("todo-closed", "The demo tasks are done.")
				: answer("todo-answer", "Three demo tasks are in the todo list.\nShould I start on the first one?");
		case "ask":
			return answer("ask-answer", `Noted: ${result.trim().replaceAll("\n", "; ").replace(/\.$/, "")}.`);
		default:
			return answer("tool-answer", `The \`${name}\` call finished.`);
	}
}

/** Starts a demo cycle. The returned function answers one request, or returns undefined for a side request. */
export function createDemo(): (body: Record<string, unknown>) => DemoReply | undefined {
	let next = 0;
	return body => {
		if (!Array.isArray(body.tools) || body.tools.length === 0) return undefined;
		const messages = Array.isArray(body.messages) ? body.messages.filter(isRecord) : [];
		const prompt = messages.findLastIndex(
			m => m.role === "user" && texts(m).some(text => !text.trimStart().startsWith("<system-")),
		);
		const lastReply = messages.findLastIndex(m => m.role === "assistant");
		if (lastReply < prompt || lastReply === -1) {
			const scenario = SCENARIOS[next % SCENARIOS.length]!;
			next++;
			return scenario;
		}
		const last = messages.at(-1);
		if (last?.role === "tool") return afterTool(toolName(messages, last.tool_call_id), texts(last).join("\n"));
		const injected = messages.slice(lastReply + 1).flatMap(texts).join("\n");
		if (!/todo/i.test(injected)) return answer("continue", "Noted.");
		return {
			label: "todo-close",
			turn: { steps: [{ text: "Closing the demo tasks." }, call("todo", { i: "Closing the demo tasks", op: "done" })] },
		};
	};
}
