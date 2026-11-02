// Port of lib/screens/chat/ask.dart: the companion's `ask` request and its answer (docs/contracts/ompx.md, "Requests").
import { FormatException, isJsonObject, type JsonObject } from "../../../core/rpc/json_fields";

export interface AskOption {
  readonly label: string;
  readonly description?: string;
  /** Text shown when the option is chosen, e.g. the code the option would produce. */
  readonly preview?: string;
}

export interface AskQuestion {
  readonly id: string;
  readonly question: string;
  /** Short label of the question, e.g. `Color`. */
  readonly header?: string;
  readonly options: readonly AskOption[];
  readonly multi: boolean;
  /** Index into `options`. */
  readonly recommended?: number;
}

export interface AskParams {
  readonly questions: readonly AskQuestion[];
  /** Host epoch milliseconds at which the companion answers with the recommended options. */
  readonly deadlineMs?: number;
}

/** Throws FormatException when `params` do not follow the contract. */
export function askParamsFromJson(params: { readonly [key: string]: unknown }): AskParams {
  const questions = params.questions;
  if (!Array.isArray(questions) || questions.length === 0) throw new FormatException('ask: "questions" is not a list');
  const deadline = params.deadline;
  return {
    questions: questions.map(askQuestionFromJson),
    deadlineMs: typeof deadline === "number" && Number.isInteger(deadline) ? deadline : undefined,
  };
}

function askQuestionFromJson(json: unknown): AskQuestion {
  const map = jsonObject(json, "question");
  const options = map.options;
  if (!Array.isArray(options)) throw new FormatException('ask question: "options" is not a list');
  const recommended = map.recommended;
  return {
    id: requiredString(map, "id"),
    question: requiredString(map, "question"),
    header: nonEmptyString(map, "header"),
    options: options.map(askOptionFromJson),
    multi: map.multi === true,
    recommended:
      typeof recommended === "number" && Number.isInteger(recommended) && recommended >= 0 && recommended < options.length
        ? recommended
        : undefined,
  };
}

function askOptionFromJson(json: unknown): AskOption {
  const map = jsonObject(json, "option");
  return {
    label: requiredString(map, "label"),
    description: nonEmptyString(map, "description"),
    preview: nonEmptyString(map, "preview"),
  };
}

/** What the user has entered for one question. */
export interface AskDraft {
  /** Chosen option labels. */
  readonly selected: readonly string[];
  /** "Other" is chosen; `custom` holds its text. */
  readonly other: boolean;
  readonly custom: string;
  readonly note: string;
}

/** A draft with the recommended option chosen for a single-choice question, as the TUI preselects it. */
export function askDraftInitial(question: AskQuestion): AskDraft {
  const recommended = question.recommended === undefined ? undefined : question.options[question.recommended];
  return {
    selected: !question.multi && recommended !== undefined ? [recommended.label] : [],
    other: false,
    custom: "",
    note: "",
  };
}

/** Chooses `label`: the only choice of a single-choice question, toggled in a multi-choice one. */
export function askChoose(question: AskQuestion, draft: AskDraft, label: string): AskDraft {
  if (question.multi) {
    const selected = draft.selected.includes(label)
      ? draft.selected.filter((chosen) => chosen !== label)
      : [...draft.selected, label];
    return { ...draft, selected };
  }
  return { ...draft, selected: [label], other: false };
}

/** Chooses "Other": exclusive in a single-choice question, toggled in a multi-choice one. */
export function askChooseOther(question: AskQuestion, draft: AskDraft): AskDraft {
  if (question.multi) return { ...draft, other: !draft.other };
  return { ...draft, selected: [], other: true };
}

/** The "Other" answer's text is now `text`; typing an answer chooses "Other". */
export function askTypeOther(question: AskQuestion, draft: AskDraft, text: string): AskDraft {
  const chosen = text.length > 0 && !draft.other ? askChooseOther(question, draft) : draft;
  return { ...chosen, custom: text };
}

export function askDraftAnswered(draft: AskDraft): boolean {
  return draft.selected.length > 0 || (draft.other && draft.custom.trim().length > 0);
}

/** True when every question has a choice or "Other" text. */
export function askComplete(drafts: readonly AskDraft[]): boolean {
  return drafts.every(askDraftAnswered);
}

/** The `submit` answer: one result per question, in order, with option labels in the options' order. */
export function askSubmit(questions: readonly AskQuestion[], drafts: readonly AskDraft[]): JsonObject {
  if (questions.length !== drafts.length) throw new RangeError("Invalid argument: one draft per question");
  return {
    kind: "submit",
    results: questions.map((question, index) => {
      const draft = drafts[index] as AskDraft;
      const result: JsonObject = {
        id: question.id,
        selectedOptions: question.options
          .filter((option) => draft.selected.includes(option.label))
          .map((option) => option.label),
      };
      const custom = draft.custom.trim();
      if (draft.other && custom.length > 0) result.customInput = custom;
      const note = draft.note.trim();
      if (note.length > 0) result.note = note;
      return result;
    }),
  };
}

/** The user wants to talk about the questions instead of answering them. */
export const askChat: JsonObject = { kind: "chat" };

function jsonObject(json: unknown, what: string): JsonObject {
  if (!isJsonObject(json)) throw new FormatException(`ask: ${what} is not an object`);
  return json;
}

function requiredString(json: JsonObject, key: string): string {
  const value = json[key];
  if (typeof value !== "string") throw new FormatException(`ask: "${key}" is not a string`);
  return value;
}

function nonEmptyString(json: JsonObject, key: string): string | undefined {
  const value = json[key];
  return typeof value === "string" && value.length > 0 ? value : undefined;
}
