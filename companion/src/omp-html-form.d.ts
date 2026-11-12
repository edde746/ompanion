/**
 * omp's form modules (`packages/tui/src/html-form/`), added in omp 18.18.3 with its form-based `ask` tool. The
 * companion's dev types are omp 18.16.0's, which have none of them; these declarations carry what `form.ts` uses,
 * as omp 18.19.0 defines it. Delete this file once the dev types are 18.18.3 or newer.
 */
declare module "@oh-my-pi/pi-tui/html-form/parse" {
	export type FormSpanStyle = "code" | "strong" | "em";

	/** A run of inline text; `"\n"` inside `text` is a hard line break (`<br>`). */
	export interface FormSpan {
		text: string;
		style?: FormSpanStyle;
	}

	export interface ChoiceOption {
		value: string;
		label: FormSpan[];
		checked: boolean;
		disabled: boolean;
	}

	/** A radio group (`multi: false`), checkbox group (`multi: true`) or `<select>` (`select: true`). */
	export interface ChoiceField {
		kind: "choice";
		name: string;
		multi: boolean;
		select: boolean;
		/** The UI adds a free-text "Other" answer. */
		other: boolean;
		label: FormSpan[];
		options: ChoiceOption[];
		required: boolean;
	}

	/** A single-line `<input>` (`multiline: false`) or a `<textarea>`. */
	export interface TextField {
		kind: "text";
		name: string;
		type: string;
		multiline: boolean;
		label: FormSpan[];
		value: string;
		placeholder: string;
		required: boolean;
		min?: number;
		max?: number;
		pattern?: string;
		minLength?: number;
		maxLength?: number;
		rows: number;
	}

	export type FormField = ChoiceField | TextField;

	export type FormBlock =
		| { kind: "text"; spans: FormSpan[]; heading: boolean }
		| { kind: "list"; items: FormSpan[][]; ordered: boolean }
		| { kind: "pre"; text: string }
		| { kind: "table"; rows: FormSpan[][][]; headerRows: number }
		| { kind: "image"; src: string; alt: string }
		| { kind: "svg"; markup: string; alt: string }
		| { kind: "field"; field: FormField };

	export interface FormSection {
		title: FormSpan[];
		blocks: FormBlock[];
	}

	export interface HtmlForm {
		sections: FormSection[];
		fields: FormField[];
		hidden: [name: string, value: string][];
	}

	export function parseHtmlForm(html: string): HtmlForm;
}

declare module "@oh-my-pi/pi-tui/html-form/data" {
	import type { ChoiceField, FormField, HtmlForm } from "@oh-my-pi/pi-tui/html-form/parse";

	export type HtmlFormValue = string | number | string[];
	export type HtmlFormData = Record<string, HtmlFormValue>;

	export function isArrayChoice(field: ChoiceField): boolean;
	export function defaultFormData(form: HtmlForm): HtmlFormData;
	export function fieldQuestions(form: HtmlForm): Map<FormField, string>;
	export function fieldError(field: FormField, value: HtmlFormValue | undefined): string | undefined;
}

declare module "@oh-my-pi/pi-tui/html-form/media" {
	export interface FormMedia {
		bytes: Uint8Array;
		mime: string;
	}

	export function loadFormImage(src: string, options: { cwd: string; signal?: AbortSignal }): Promise<FormMedia>;
	export function svgMedia(markup: string): FormMedia;
}
