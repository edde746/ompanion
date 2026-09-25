import { describe, expect, test } from "bun:test";
import type { ExtensionAskDialogQuestion } from "@oh-my-pi/pi-coding-agent";
import { answerFromApp, normalizeQuestions, timeoutAnswer } from "../src/ask.ts";

const color: ExtensionAskDialogQuestion = {
	id: "color",
	question: "Which color?",
	options: [{ label: "Red" }, { label: "Blue", description: "calm" }, { label: "Green" }],
	recommended: 1,
};
const tools: ExtensionAskDialogQuestion = {
	id: "tools",
	question: "Which tools?",
	options: [{ label: "bash" }, { label: "read" }, { label: "edit" }],
	multi: true,
};

describe("normalizeQuestions", () => {
	test("coerces malformed extension input into the wire shape", () => {
		expect(
			normalizeQuestions([
				{ id: 7, question: "Q", header: "H", options: [{ label: "A", preview: "p" }, "junk", { label: 3 }], recommended: 1.5 },
				null,
				{ id: "b", options: "none", multi: "yes" },
			]),
		).toEqual([
			{ id: "?", question: "Q", header: "H", options: [{ label: "A", preview: "p" }, { label: "" }] },
			{ id: "b", question: "", options: [] },
		]);
		expect(normalizeQuestions("nope")).toEqual([]);
	});
});

describe("timeoutAnswer", () => {
	test("picks the recommended option, else the first, like the TUI dialog", () => {
		expect(timeoutAnswer([color, tools, { id: "far", question: "?", options: [{ label: "x" }], recommended: 9 }])).toEqual({
			kind: "submit",
			results: [
				{ id: "color", question: "Which color?", options: ["Red", "Blue", "Green"], multi: false, selectedOptions: ["Blue"], timedOut: true },
				{ id: "tools", question: "Which tools?", options: ["bash", "read", "edit"], multi: true, selectedOptions: ["bash"], timedOut: true },
				{ id: "far", question: "?", options: ["x"], multi: false, selectedOptions: ["x"], timedOut: true },
			],
		});
	});

	test("a question without options times out with nothing selected", () => {
		expect(timeoutAnswer([{ id: "q", question: "?", options: [] }]).results[0]?.selectedOptions).toEqual([]);
	});
});

describe("answerFromApp", () => {
	test("maps a submit to the tool's result items, selections in option order", () => {
		expect(
			answerFromApp(
				{
					kind: "submit",
					results: [
						{ id: "color", selectedOptions: [], customInput: "Purple", note: "any dark shade" },
						{ id: "tools", selectedOptions: ["edit", "bash"] },
					],
				},
				[color, tools],
			),
		).toEqual({
			kind: "submit",
			results: [
				{
					id: "color",
					question: "Which color?",
					options: ["Red", "Blue", "Green"],
					multi: false,
					selectedOptions: [],
					customInput: "Purple",
					note: "any dark shade",
				},
				{ id: "tools", question: "Which tools?", options: ["bash", "read", "edit"], multi: true, selectedOptions: ["bash", "edit"] },
			],
		});
	});

	test("chat needs no results", () => {
		expect(answerFromApp({ kind: "chat" }, [color])).toEqual({ kind: "chat" });
	});

	test("rejects answers that do not fit the questions", () => {
		const cases: [unknown, string][] = [
			[{ kind: "cancel" }, "kind"],
			[{ kind: "submit", results: [] }, "1 results"],
			[{ kind: "submit", results: [{ id: "tools", selectedOptions: [] }] }, 'question "color"'],
			[{ kind: "submit", results: [{ id: "color", selectedOptions: ["Purple"] }] }, "option labels"],
			[{ kind: "submit", results: [{ id: "color", selectedOptions: ["Red", "Blue"] }] }, "single-select"],
			[{ kind: "submit", results: [{ id: "color", selectedOptions: [], note: 1 }] }, "note"],
			["submit", "object"],
		];
		for (const [answer, message] of cases) expect(() => answerFromApp(answer, [color])).toThrow(message);
	});
});
