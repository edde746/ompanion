import type {
	ExtensionAskDialogQuestion,
	ExtensionAskDialogResult,
	ExtensionAskDialogResultItem,
	ExtensionAskDialogSubmitResult,
	ExtensionUIDialogOptions,
} from "@oh-my-pi/pi-coding-agent";
import { isRecord } from "./args.ts";
import { channel } from "./channel.ts";
import { notifyInput } from "./notify.ts";

/** Params of the companion request `ask` (docs/contracts/ompx.md). */
export interface AskParams {
	questions: ExtensionAskDialogQuestion[];
	/** Milliseconds after which the companion answers by itself; absent when `ask.timeout` is 0. */
	timeout?: number;
	/** Host epoch milliseconds at which that happens. */
	deadline?: number;
}

/**
 * Coerces caller-supplied questions into the documented shape, like the TUI's
 * `normalizeDialogQuestions`: `askDialog` is a public extension surface, so entries can be malformed.
 */
export function normalizeQuestions(questions: unknown): ExtensionAskDialogQuestion[] {
	if (!Array.isArray(questions)) return [];
	return questions.filter(isRecord).map(question => ({
		id: typeof question.id === "string" ? question.id : "?",
		question: typeof question.question === "string" ? question.question : "",
		...(typeof question.header === "string" ? { header: question.header } : {}),
		options: (Array.isArray(question.options) ? question.options : []).filter(isRecord).map(option => ({
			label: typeof option.label === "string" ? option.label : "",
			...(typeof option.description === "string" ? { description: option.description } : {}),
			...(typeof option.preview === "string" ? { preview: option.preview } : {}),
		})),
		...(typeof question.multi === "boolean" ? { multi: question.multi } : {}),
		...(typeof question.recommended === "number" && Number.isInteger(question.recommended)
			? { recommended: question.recommended }
			: {}),
	}));
}

/**
 * What the TUI dialog submits when its countdown ends (ask-dialog.ts `#handleTimeout`): every
 * question gets its recommended option, else the first, marked `timedOut`.
 */
export function timeoutAnswer(questions: readonly ExtensionAskDialogQuestion[]): ExtensionAskDialogSubmitResult {
	return {
		kind: "submit",
		results: questions.map(question => {
			const labels = question.options.map(option => option.label);
			const index = Math.min(Math.max(question.recommended ?? 0, 0), Math.max(0, labels.length - 1));
			const fallback = labels[index];
			return {
				id: question.id,
				question: question.question,
				options: labels,
				multi: question.multi ?? false,
				selectedOptions: fallback === undefined ? [] : [fallback],
				timedOut: true,
			};
		}),
	};
}

function answerItem(question: ExtensionAskDialogQuestion, raw: unknown, index: number): ExtensionAskDialogResultItem {
	if (!isRecord(raw) || raw.id !== question.id) {
		throw new Error(`ask answer: results[${index}] must answer question "${question.id}"`);
	}
	const labels = question.options.map(option => option.label);
	const selected = raw.selectedOptions;
	if (!Array.isArray(selected) || !selected.every(label => typeof label === "string" && labels.includes(label))) {
		throw new Error(`ask answer: results[${index}].selectedOptions must list option labels of "${question.id}"`);
	}
	if (question.multi !== true && selected.length > 1) {
		throw new Error(`ask answer: question "${question.id}" is single-select`);
	}
	const { customInput, note } = raw;
	if (customInput !== undefined && typeof customInput !== "string") {
		throw new Error(`ask answer: results[${index}].customInput must be a string`);
	}
	if (note !== undefined && typeof note !== "string") {
		throw new Error(`ask answer: results[${index}].note must be a string`);
	}
	return {
		id: question.id,
		question: question.question,
		options: labels,
		multi: question.multi ?? false,
		// Option order, as the TUI dialog reports them.
		selectedOptions: labels.filter(label => selected.includes(label)),
		...(customInput === undefined ? {} : { customInput }),
		...(note === undefined ? {} : { note }),
	};
}

/**
 * Maps the app's answer to the dialog result the ask tool expects.
 *
 * @throws Error when the answer does not fit the questions.
 */
export function answerFromApp(value: unknown, questions: readonly ExtensionAskDialogQuestion[]): ExtensionAskDialogResult {
	if (!isRecord(value)) throw new Error("ask answer must be an object");
	if (value.kind === "chat") return { kind: "chat" };
	if (value.kind !== "submit") throw new Error('ask answer kind must be "submit" or "chat"');
	const { results } = value;
	if (!Array.isArray(results) || results.length !== questions.length) {
		throw new Error(`ask answer must carry ${questions.length} results, one per question in order`);
	}
	return { kind: "submit", results: questions.map((question, index) => answerItem(question, results[index], index)) };
}

/**
 * `ctx.ui.askDialog` for rpc-ui: omp's native ask tool uses it when present (tools/ask.ts 926-1012).
 * The companion enforces the timeout itself, because no device may be attached when it expires.
 */
export async function askDialog(
	questions: ExtensionAskDialogQuestion[],
	dialogOptions?: ExtensionUIDialogOptions,
): Promise<ExtensionAskDialogResult | undefined> {
	const normalized = normalizeQuestions(questions);
	const first = normalized[0];
	if (first) notifyInput(first.question);
	const timeout = dialogOptions?.timeout !== undefined && dialogOptions.timeout > 0 ? dialogOptions.timeout : undefined;
	const expiry = new AbortController();
	const outer = dialogOptions?.signal;
	const signal = outer ? AbortSignal.any([outer, expiry.signal]) : expiry.signal;
	const timer = timeout === undefined ? undefined : setTimeout(() => expiry.abort(), timeout);
	const params: AskParams = {
		questions: normalized,
		...(timeout === undefined ? {} : { timeout, deadline: Date.now() + timeout }),
	};
	try {
		const value = await channel().request("ask", params, signal);
		if (value !== undefined) return answerFromApp(value, normalized);
		if (expiry.signal.aborted && !outer?.aborted) {
			dialogOptions?.onTimeout?.();
			return timeoutAnswer(normalized);
		}
		return undefined;
	} finally {
		clearTimeout(timer);
	}
}
