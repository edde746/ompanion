// The companion's `form` request: omp's `ask` tool from 18.18.3, one HTML form that omp parsed on the host
// (docs/contracts/ompx.md, "Requests", `form`), and the answer the app sends back. The values and rules follow
// omp's own (`tui/src/html-form/data.ts`), which the companion applies again before omp sees the answer.
import {
  asJsonObject,
  boolean,
  FormatException,
  integer,
  type JsonObject,
  list,
  optInt,
  optNumber,
  optString,
  string,
} from "../../../core/rpc/json_fields";

/** A run of inline text; `"\n"` in `text` is a hard line break. */
export interface FormSpan {
  readonly text: string;
  readonly style?: "code" | "strong" | "em";
}

export interface FormOption {
  readonly value: string;
  readonly label: readonly FormSpan[];
  readonly checked: boolean;
  readonly disabled: boolean;
}

/** A radio group (`multi: false`), checkbox group (`multi: true`) or `<select>` (`select: true`). */
export interface FormChoice {
  readonly kind: "choice";
  readonly name: string;
  /** The question it answers: its label, the text before it, its section's title or its name. */
  readonly question: string;
  /** Its own label: a select's; empty for a radio or checkbox group, whose question is the text around it. */
  readonly label: readonly FormSpan[];
  readonly multi: boolean;
  readonly select: boolean;
  /** The form adds a typed "Other" answer. */
  readonly other: boolean;
  readonly required: boolean;
  readonly options: readonly FormOption[];
}

/** An `<input>` (`multiline: false`) or a `<textarea>`. */
export interface FormInput {
  readonly kind: "input";
  readonly name: string;
  readonly question: string;
  readonly label: readonly FormSpan[];
  /** The `<input type>`; `textarea` for a textarea. */
  readonly type: string;
  readonly multiline: boolean;
  readonly value: string;
  readonly placeholder: string;
  readonly required: boolean;
  readonly rows: number;
  readonly min?: number;
  readonly max?: number;
  readonly pattern?: string;
  readonly minLength?: number;
  readonly maxLength?: number;
}

export type FormField = FormChoice | FormInput;

/** A table's rows of cells, each cell a run of spans. */
type FormRows = readonly (readonly (readonly FormSpan[])[])[];

export type FormBlock =
  | { readonly kind: "text"; readonly spans: readonly FormSpan[]; readonly heading: boolean }
  | { readonly kind: "list"; readonly items: readonly (readonly FormSpan[])[]; readonly ordered: boolean }
  | { readonly kind: "pre"; readonly text: string }
  | { readonly kind: "table"; readonly rows: FormRows; readonly headerRows: number }
  /** A picture; `uri` is a `data:` URI the host loaded, absent when it could not load it. */
  | { readonly kind: "image"; readonly alt: string; readonly uri?: string }
  | FormField;

export interface FormSection {
  readonly title: readonly FormSpan[];
  readonly blocks: readonly FormBlock[];
}

export interface HtmlForm {
  readonly sections: readonly FormSection[];
  /** Every field of `sections`, in document order: the order of the drafts. */
  readonly fields: readonly FormField[];
  /** Host epoch milliseconds at which the companion submits the preselected values. */
  readonly deadlineMs?: number;
}

/** Throws FormatException when `params` do not follow the contract. */
export function htmlFormFromJson(params: { readonly [key: string]: unknown }): HtmlForm {
  const json: JsonObject = { ...params };
  const sections = list(json, "sections").map((section) => {
    const object = asJsonObject(section, "form section");
    return { title: spans(object, "title"), blocks: list(object, "blocks").map(block) };
  });
  return {
    sections,
    fields: sections.flatMap((section) =>
      section.blocks.filter((item): item is FormField => item.kind === "choice" || item.kind === "input"),
    ),
    deadlineMs: optInt(json, "deadline"),
  };
}

function spanList(value: unknown): FormSpan[] {
  if (!Array.isArray(value)) throw new FormatException(`form: ${JSON.stringify(value)} is not a list of spans`);
  return value.map((item) => {
    const span = asJsonObject(item, "form span");
    const style = optString(span, "style");
    if (style !== undefined && style !== "code" && style !== "strong" && style !== "em") {
      throw new FormatException(`form: span style "${style}" is unknown`);
    }
    return { text: string(span, "text"), ...(style === undefined ? {} : { style }) };
  });
}

function spans(json: JsonObject, key: string): FormSpan[] {
  return spanList(list(json, key));
}

function block(value: unknown): FormBlock {
  const json = asJsonObject(value, "form block");
  const kind = string(json, "kind");
  switch (kind) {
    case "text":
      return { kind, spans: spans(json, "spans"), heading: boolean(json, "heading") };
    case "list":
      return { kind, items: list(json, "items").map(spanList), ordered: boolean(json, "ordered") };
    case "pre":
      return { kind, text: string(json, "text") };
    case "table":
      return {
        kind,
        rows: list(json, "rows").map((row) => {
          if (!Array.isArray(row)) throw new FormatException("form: a table row is not a list");
          return row.map(spanList);
        }),
        headerRows: integer(json, "headerRows"),
      };
    case "image": {
      const uri = json.uri;
      if (uri !== null && typeof uri !== "string") throw new FormatException("form: an image's uri is not a string");
      // Only a `data:` URI: the host loaded the picture, so the app fetches nothing.
      const picture = typeof uri === "string" && uri.startsWith("data:image/") ? uri : undefined;
      return { kind, alt: string(json, "alt"), uri: picture };
    }
    case "choice":
      return {
        kind,
        name: string(json, "name"),
        question: string(json, "question"),
        label: spans(json, "label"),
        multi: boolean(json, "multi"),
        select: boolean(json, "select"),
        other: boolean(json, "other"),
        required: boolean(json, "required"),
        options: list(json, "options").map((option) => {
          const object = asJsonObject(option, "form option");
          return {
            value: string(object, "value"),
            label: spans(object, "label"),
            checked: boolean(object, "checked"),
            disabled: boolean(object, "disabled"),
          };
        }),
      };
    case "input":
      return {
        kind,
        name: string(json, "name"),
        question: string(json, "question"),
        label: spans(json, "label"),
        type: string(json, "type"),
        multiline: boolean(json, "multiline"),
        value: string(json, "value"),
        placeholder: string(json, "placeholder"),
        required: boolean(json, "required"),
        rows: integer(json, "rows"),
        min: optNumber(json, "min"),
        max: optNumber(json, "max"),
        pattern: optString(json, "pattern"),
        minLength: optInt(json, "minLength"),
        maxLength: optInt(json, "maxLength"),
      };
    default:
      throw new FormatException(`form: block kind "${kind}" is unknown`);
  }
}

/** Plain text of `spans`. */
export function spansText(spans: readonly FormSpan[]): string {
  return spans.map((span) => span.text).join("");
}

/** What the user entered for one field. */
export type FieldDraft =
  | {
      readonly kind: "choice";
      /** Indices of the chosen options. */
      readonly checked: readonly number[];
      /** "Other" is chosen; `otherText` holds its text. */
      readonly other: boolean;
      readonly otherText: string;
    }
  | { readonly kind: "input"; readonly text: string };

/** The drafts a form opens with, one per field: its preselected options and prefilled text. */
export function htmlFormDrafts(form: HtmlForm): FieldDraft[] {
  return form.fields.map((field) =>
    field.kind === "input"
      ? { kind: "input", text: field.value }
      : {
          kind: "choice",
          checked: field.options.flatMap((option, index) => (option.checked ? [index] : [])),
          other: false,
          otherText: "",
        },
  );
}

/** Whether a choice submits a list (a checkbox group, a multi-select) rather than one value: omp's `isArrayChoice`. */
export function isArrayChoice(field: FormChoice): boolean {
  return field.multi && field.options.length > 1;
}

function choiceDraft(draft: FieldDraft): Extract<FieldDraft, { kind: "choice" }> {
  if (draft.kind !== "choice") throw new RangeError("Invalid argument: not a choice's draft");
  return draft;
}

/** Chooses option `index`: the only choice of a radio group or select, toggled in a checkbox group. */
export function chooseOption(field: FormChoice, draft: FieldDraft, index: number): FieldDraft {
  const choice = choiceDraft(draft);
  if (!field.multi) return { ...choice, checked: [index], other: false };
  const checked = choice.checked.includes(index)
    ? choice.checked.filter((chosen) => chosen !== index)
    : [...choice.checked, index].sort((a, b) => a - b);
  return { ...choice, checked };
}

/** Chooses "Other": exclusive in a radio group, toggled in a checkbox group. */
export function chooseOther(field: FormChoice, draft: FieldDraft): FieldDraft {
  const choice = choiceDraft(draft);
  if (field.multi) return { ...choice, other: !choice.other };
  return { ...choice, checked: [], other: true };
}

/** The "Other" text is now `text`; typing it chooses "Other". */
export function typeOther(field: FormChoice, draft: FieldDraft, text: string): FieldDraft {
  const choice = choiceDraft(draft);
  const chosen = text.length > 0 && !choice.other ? choiceDraft(chooseOther(field, choice)) : choice;
  return { ...chosen, otherText: text };
}

/** How many answers a choice has: chosen options and a non-blank "Other". */
export function chosenCount(draft: FieldDraft): number {
  const choice = choiceDraft(draft);
  return choice.checked.length + (choice.other && choice.otherText.trim() !== "" ? 1 : 0);
}

export type FormValue = string | number | readonly string[];

/**
 * The value a field submits, as omp's `choiceValue` and `textValue` compute it: a radio's or select's value (the
 * "Other" text in its place), a group's values with the "Other" text last, a number for a filled `number` or `range`
 * input, else the text. Undefined when a single choice has none.
 */
export function fieldValue(field: FormField, draft: FieldDraft): FormValue | undefined {
  if (field.kind === "input") {
    if (draft.kind !== "input") throw new RangeError("Invalid argument: not an input's draft");
    if ((field.type === "number" || field.type === "range") && draft.text.trim() !== "") {
      const number = Number(draft.text);
      if (Number.isFinite(number)) return number;
    }
    return draft.text;
  }
  const choice = choiceDraft(draft);
  const typed = field.other && choice.other ? choice.otherText.trim() : undefined;
  const values = field.options.flatMap((option, index) =>
    choice.checked.includes(index) && !option.disabled ? [option.value] : [],
  );
  if (isArrayChoice(field)) return typed ? [...values, typed] : values;
  return typed || values[0];
}

/** Why a field's value is not acceptable, as omp's `fieldError` says it. */
export type FieldError =
  | { readonly kind: "required" }
  | { readonly kind: "chooseOne" }
  | { readonly kind: "number" }
  | { readonly kind: "min"; readonly min: number }
  | { readonly kind: "max"; readonly max: number }
  | { readonly kind: "minLength"; readonly length: number }
  | { readonly kind: "maxLength"; readonly length: number }
  | { readonly kind: "email" }
  | { readonly kind: "url" }
  | { readonly kind: "pattern"; readonly pattern: string };

/**
 * omp's `fieldError`: `required`, a number's `min` and `max`, `minlength` and `maxlength`, an `email` or `url` shape,
 * and `pattern`, anchored as HTML anchors it (an invalid pattern is ignored).
 */
export function fieldError(field: FormField, value: FormValue | undefined): FieldError | undefined {
  if (field.kind === "choice") {
    const empty = value === undefined || (Array.isArray(value) && value.length === 0);
    if (!field.required || !empty) return undefined;
    return isArrayChoice(field) ? { kind: "chooseOne" } : { kind: "required" };
  }
  const text = value === undefined ? "" : String(value);
  if (text.trim() === "") return field.required ? { kind: "required" } : undefined;
  if (field.type === "number" || field.type === "range") {
    const number = Number(text);
    if (!Number.isFinite(number)) return { kind: "number" };
    if (field.min !== undefined && number < field.min) return { kind: "min", min: field.min };
    if (field.max !== undefined && number > field.max) return { kind: "max", max: field.max };
  }
  if (field.minLength !== undefined && text.length < field.minLength) {
    return { kind: "minLength", length: field.minLength };
  }
  if (field.maxLength !== undefined && text.length > field.maxLength) {
    return { kind: "maxLength", length: field.maxLength };
  }
  if (field.type === "email" && !/^[^\s@]+@[^\s@]+$/.test(text)) return { kind: "email" };
  if (field.type === "url" && !isUrl(text)) return { kind: "url" };
  if (field.pattern && compilePattern(field.pattern)?.test(text) === false) {
    return { kind: "pattern", pattern: field.pattern };
  }
  return undefined;
}

/** `URL.canParse`, which Safari has from 17 only. */
function isUrl(text: string): boolean {
  try {
    new URL(text);
    return true;
  } catch (error) {
    if (error instanceof TypeError) return false;
    throw error;
  }
}

/**
 * `^(?:pattern)$` with the `v` flag, as HTML compiles a pattern; `u` where the engine lacks `v` (Safari before 17).
 * Undefined for a pattern neither compiles, which HTML ignores.
 */
function compilePattern(pattern: string): RegExp | undefined {
  for (const flags of ["v", "u"]) {
    try {
      return new RegExp(`^(?:${pattern})$`, flags);
    } catch (error) {
      if (!(error instanceof SyntaxError)) throw error;
    }
  }
  return undefined;
}

/** Each field's error, in field order. */
export function htmlFormErrors(form: HtmlForm, drafts: readonly FieldDraft[]): (FieldError | undefined)[] {
  return form.fields.map((field, index) => fieldError(field, fieldValue(field, draftAt(drafts, index))));
}

function draftAt(drafts: readonly FieldDraft[], index: number): FieldDraft {
  const draft = drafts[index];
  if (draft === undefined) throw new RangeError("Invalid argument: one draft per field");
  return draft;
}

/**
 * The `submit` answer: every field's value by name, as omp's form data has it; a single choice without an answer is
 * left out. The companion adds the hidden inputs.
 */
export function htmlFormSubmit(form: HtmlForm, drafts: readonly FieldDraft[]): JsonObject {
  if (drafts.length !== form.fields.length) throw new RangeError("Invalid argument: one draft per field");
  const data: JsonObject = {};
  form.fields.forEach((field, index) => {
    const value = fieldValue(field, draftAt(drafts, index));
    if (value !== undefined) data[field.name] = value;
  });
  return { kind: "submit", data };
}
