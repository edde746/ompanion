import type { ExtensionUIDialogOptions } from "@oh-my-pi/pi-coding-agent";
import type { HtmlFormData, HtmlFormValue } from "@oh-my-pi/pi-tui/html-form/data";
import type { ChoiceField, FormField, FormSpan, HtmlForm, TextField } from "@oh-my-pi/pi-tui/html-form/parse";
import { isRecord } from "./args.ts";
import { channel } from "./channel.ts";
import { notifyInput } from "./notify.ts";

/** A radio group, checkbox group or `<select>` as the app draws it: omp's `ChoiceField` and the question it answers. */
export interface ChoiceBlock {
	kind: "choice";
	name: string;
	question: string;
	label: FormSpan[];
	multi: boolean;
	select: boolean;
	other: boolean;
	required: boolean;
	options: { value: string; label: FormSpan[]; checked: boolean; disabled: boolean }[];
}

/** An `<input>` or `<textarea>` as the app draws it: omp's `TextField` and the question it answers. */
export interface InputBlock {
	kind: "input";
	name: string;
	question: string;
	label: FormSpan[];
	type: string;
	multiline: boolean;
	value: string;
	placeholder: string;
	required: boolean;
	rows: number;
	min?: number;
	max?: number;
	pattern?: string;
	minLength?: number;
	maxLength?: number;
}

export type FormBlockParams =
	| { kind: "text"; spans: FormSpan[]; heading: boolean }
	| { kind: "list"; items: FormSpan[][]; ordered: boolean }
	| { kind: "pre"; text: string }
	| { kind: "table"; rows: FormSpan[][][]; headerRows: number }
	/** An `<img>` or inline `<svg>`; `uri` is a `data:` URI, null when the picture could not be loaded. */
	| { kind: "image"; alt: string; uri: string | null }
	| ChoiceBlock
	| InputBlock;

/** Params of the companion request `form` (docs/contracts/ompx.md). */
export interface FormParams {
	sections: { title: FormSpan[]; blocks: FormBlockParams[] }[];
	/** Milliseconds after which the companion answers by itself; absent when `ask.timeout` is 0. */
	timeout?: number;
	/** Host epoch milliseconds at which that happens. */
	deadline?: number;
}

/** omp's `ExtensionFormDialogResult` (18.18.3+): the form data, flagged when the timeout submitted the defaults. */
export interface FormDialogResult {
	data: HtmlFormData;
	timedOut?: boolean;
}

type FormMedia = { bytes: Uint8Array; mime: string };

/** omp's form functions the companion uses. */
export interface HtmlForms {
	parseHtmlForm(html: string): HtmlForm;
	defaultFormData(form: HtmlForm): HtmlFormData;
	fieldQuestions(form: HtmlForm): Map<FormField, string>;
	fieldError(field: FormField, value: HtmlFormValue | undefined): string | undefined;
	isArrayChoice(field: ChoiceField): boolean;
	loadFormImage(src: string, options: { cwd: string; signal?: AbortSignal }): Promise<FormMedia>;
	svgMedia(markup: string): FormMedia;
}

/**
 * omp's own form parser, data rules and picture loader, so a form means here what it means in the TUI. Imported on the
 * first form: omp has these modules from 18.18.3, the first omp whose `ask` tool calls `formDialog`, and a static
 * import would stop the companion from loading in an older omp.
 */
async function loadHtmlForms(): Promise<HtmlForms> {
	const [parse, data, media] = await Promise.all([
		import("@oh-my-pi/pi-tui/html-form/parse"),
		import("@oh-my-pi/pi-tui/html-form/data"),
		import("@oh-my-pi/pi-tui/html-form/media"),
	]);
	return {
		parseHtmlForm: parse.parseHtmlForm,
		defaultFormData: data.defaultFormData,
		fieldQuestions: data.fieldQuestions,
		fieldError: data.fieldError,
		isArrayChoice: data.isArrayChoice,
		loadFormImage: media.loadFormImage,
		svgMedia: media.svgMedia,
	};
}

function choiceBlock(field: ChoiceField, question: string): ChoiceBlock {
	return {
		kind: "choice",
		name: field.name,
		question,
		label: field.label,
		multi: field.multi,
		select: field.select,
		other: field.other,
		required: field.required,
		options: field.options.map(({ value, label, checked, disabled }) => ({ value, label, checked, disabled })),
	};
}

function inputBlock(field: TextField, question: string): InputBlock {
	const { name, label, type, multiline, value, placeholder, required, rows } = field;
	return {
		kind: "input",
		name,
		question,
		label,
		type,
		multiline,
		value,
		placeholder,
		required,
		rows,
		...(field.min === undefined ? {} : { min: field.min }),
		...(field.max === undefined ? {} : { max: field.max }),
		...(field.pattern === undefined ? {} : { pattern: field.pattern }),
		...(field.minLength === undefined ? {} : { minLength: field.minLength }),
		...(field.maxLength === undefined ? {} : { maxLength: field.maxLength }),
	};
}

function dataUri(media: FormMedia): string {
	return `data:${media.mime};base64,${Buffer.from(media.bytes).toString("base64")}`;
}

/**
 * The form as the app draws it. Fields without a `name` submit nothing, so they are left out, and so is a section left
 * empty. Pictures load here, on the host, as the TUI loads them (a URL, a `data:` URI, a path relative to `cwd`), and
 * travel as `data:` URIs, so the app neither fetches nor reads anything for them.
 */
export async function formParams(
	form: HtmlForm,
	forms: Pick<HtmlForms, "fieldQuestions" | "loadFormImage" | "svgMedia">,
	options: { cwd: string; signal?: AbortSignal },
): Promise<FormParams> {
	const questions = forms.fieldQuestions(form);
	const sections = await Promise.all(
		form.sections.map(async section => {
			const blocks = await Promise.all(
				section.blocks.map(async (block): Promise<FormBlockParams[]> => {
					switch (block.kind) {
						case "field": {
							const { field } = block;
							if (!field.name) return [];
							const question = questions.get(field) ?? field.name;
							return [field.kind === "choice" ? choiceBlock(field, question) : inputBlock(field, question)];
						}
						case "image": {
							const uri = await forms.loadFormImage(block.src, options).then(dataUri, () => null);
							return [{ kind: "image", alt: block.alt, uri }];
						}
						case "svg":
							return [{ kind: "image", alt: block.alt, uri: dataUri(forms.svgMedia(block.markup)) }];
						case "text":
							return [{ kind: "text", spans: block.spans, heading: block.heading }];
						case "list":
							return [{ kind: "list", items: block.items, ordered: block.ordered }];
						case "pre":
							return [{ kind: "pre", text: block.text }];
						case "table":
							return [{ kind: "table", rows: block.rows, headerRows: block.headerRows }];
					}
				}),
			);
			return { title: section.title, blocks: blocks.flat() };
		}),
	);
	return { sections: sections.filter(section => section.blocks.length > 0 || section.title.length > 0) };
}

/**
 * A choice's submitted value: enabled options' values (in option order for a group), and where the UI adds "Other",
 * the typed text in place of a radio's value or after a checkbox group's values.
 */
function choiceAnswer(field: ChoiceField, raw: unknown, array: boolean): HtmlFormValue | undefined {
	const values = field.options.flatMap(option => (option.disabled ? [] : [option.value]));
	if (array) {
		if (raw === undefined) return [];
		if (!Array.isArray(raw) || !raw.every(value => typeof value === "string")) {
			throw new Error(`form answer: "${field.name}" must be a list of strings`);
		}
		const typed = raw.filter(value => !values.includes(value));
		if (typed.length > (field.other ? 1 : 0)) {
			throw new Error(`form answer: "${field.name}" lists a value no option has`);
		}
		return [...values.filter(value => raw.includes(value)), ...typed];
	}
	if (raw === undefined) return undefined;
	if (typeof raw !== "string") throw new Error(`form answer: "${field.name}" must be a string`);
	if (!values.includes(raw) && !field.other) {
		throw new Error(`form answer: "${field.name}" is ${JSON.stringify(raw)}, which no option has`);
	}
	return raw;
}

function inputAnswer(field: TextField, raw: unknown): HtmlFormValue {
	if (raw === undefined) return "";
	if (typeof raw === "string") return raw;
	if (typeof raw === "number" && (field.type === "number" || field.type === "range")) return raw;
	throw new Error(`form answer: "${field.name}" must be text`);
}

/**
 * Maps the app's answer to omp's form result: the hidden inputs, then every named field's value checked by omp's own
 * rules (`fieldError`), as the TUI checks it before it submits.
 *
 * @throws Error when the answer does not fit the form.
 */
export function formAnswer(
	value: unknown,
	form: HtmlForm,
	forms: Pick<HtmlForms, "fieldQuestions" | "fieldError" | "isArrayChoice">,
): FormDialogResult {
	if (!isRecord(value) || value.kind !== "submit") throw new Error('form answer kind must be "submit"');
	const answered = value.data;
	if (!isRecord(answered)) throw new Error("form answer data must be an object");
	const named = form.fields.filter(field => field.name);
	for (const name of Object.keys(answered)) {
		if (!named.some(field => field.name === name)) throw new Error(`form answer: no field is named "${name}"`);
	}
	const questions = forms.fieldQuestions(form);
	const data: HtmlFormData = Object.fromEntries(form.hidden);
	for (const field of named) {
		const raw = answered[field.name];
		const submitted =
			field.kind === "choice" ? choiceAnswer(field, raw, forms.isArrayChoice(field)) : inputAnswer(field, raw);
		const error = forms.fieldError(field, submitted);
		if (error) throw new Error(`form answer: ${questions.get(field) ?? field.name}: ${error}`);
		if (submitted !== undefined) data[field.name] = submitted;
	}
	return { data };
}

/**
 * `ctx.ui.formDialog` for rpc-ui: omp's `ask` tool shows its HTML form through it when present (omp 18.18.3+), else
 * asks field by field with `select`/`input`/`editor`. The companion enforces the timeout itself, because no device may
 * be attached when it expires; like the TUI it then submits the form's preselected values.
 */
export function formDialog(
	cwd: () => string,
): (html: string, dialogOptions?: ExtensionUIDialogOptions) => Promise<FormDialogResult | undefined> {
	return async (html, dialogOptions) => {
		const forms = await loadHtmlForms();
		const form = forms.parseHtmlForm(html);
		const outer = dialogOptions?.signal;
		const params = await formParams(form, forms, { cwd: cwd(), signal: outer });
		const questions = forms.fieldQuestions(form);
		const first = form.fields.find(field => field.name);
		if (first) notifyInput(questions.get(first) ?? first.name);
		const timeout = dialogOptions?.timeout !== undefined && dialogOptions.timeout > 0 ? dialogOptions.timeout : undefined;
		const expiry = new AbortController();
		const signal = outer ? AbortSignal.any([outer, expiry.signal]) : expiry.signal;
		const timer = timeout === undefined ? undefined : setTimeout(() => expiry.abort(), timeout);
		const sent: FormParams = timeout === undefined ? params : { ...params, timeout, deadline: Date.now() + timeout };
		try {
			const value = await channel().request("form", sent, signal);
			if (value !== undefined) return formAnswer(value, form, forms);
			if (expiry.signal.aborted && !outer?.aborted) {
				dialogOptions?.onTimeout?.();
				return { data: forms.defaultFormData(form), timedOut: true };
			}
			return undefined;
		} finally {
			clearTimeout(timer);
		}
	};
}
