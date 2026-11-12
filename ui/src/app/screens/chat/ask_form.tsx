// Port of lib/screens/chat/ask_form.dart.
import type { JSX } from "@solidjs/web";
import { createSignal, For, Show, untrack } from "solid-js";
import { FormatException, type JsonObject } from "../../../core/rpc/json_fields";
import { t } from "../../i18n/i18n";
import { FilledButton, TextButton } from "../../widgets/button";
import { CheckboxMark, RadioMark } from "../../widgets/checkbox";
import { TextField } from "../../widgets/text_field";
import {
  type AskDraft,
  type AskParams,
  type AskQuestion,
  askChat,
  askChoose,
  askChooseOther,
  askComplete,
  askDraftInitial,
  askParamsFromJson,
  askSubmit,
  askTypeOther,
} from "./ask";
import "./ask_form.css";
import { RequestFrame } from "./request_frame";
import type { RequestDraft } from "./requests";
import "./transcript/code_style.css";
import { TranscriptMarkdown } from "./transcript/markdown";

/**
 * The companion's full-fidelity `ask` form, inline: every question with its header, options with descriptions,
 * previews and the recommended mark, multi-select, an "Other" answer and a note, plus "chat about this".
 *
 * A single-choice question's options sit in one track, the chosen one a pill in it, as a segmented control's; a
 * multi-choice question's are separate tiles with check boxes, each chosen one lit, and its hint counts them.
 */
export function AskForm(props: {
  readonly params: { readonly [key: string]: unknown };
  /**
   * Holds the answers entered so far, one per question: empty the first time, filled and kept up to date here, so a
   * form the user navigated away from comes back as it was left.
   */
  readonly draft: RequestDraft;
  readonly busy: boolean;
  readonly error?: string;
  /** Called with the `ask` answer value (`{kind: "submit" | "chat", …}`). */
  readonly onSubmit: (answer: JsonObject) => void;
  /** Cancels the request, which aborts the turn as Esc does in the TUI. */
  readonly onCancel: () => void;
  readonly navigation?: JSX.Element;
}) {
  const draft = untrack(() => props.draft);
  let params: AskParams;
  try {
    params = askParamsFromJson(untrack(() => props.params));
  } catch (error) {
    if (!(error instanceof FormatException)) throw error;
    return (
      <RequestFrame
        title={t.ask.title}
        navigation={props.navigation}
        error={props.error}
        actions={
          <TextButton disabled={props.busy} onClick={() => props.onCancel()}>
            {t.common.cancel}
          </TextButton>
        }
      >
        {t.ask.invalid({ error: error.message })}
      </RequestFrame>
    );
  }
  const questions = params.questions;
  if (draft.ask.length === 0) draft.ask = questions.map(askDraftInitial);
  const [answers, setAnswers] = createSignal(draft.ask);
  // The draft is the source of truth: a signal read in a handler returns its last committed value.
  const change = (index: number, update: (question: AskQuestion, answer: AskDraft) => AskDraft) => {
    draft.ask = draft.ask.map((answer, at) => (at === index ? update(questions[at] as AskQuestion, answer) : answer));
    setAnswers(draft.ask);
  };
  return (
    <RequestFrame
      title={questions.length === 1 ? t.ask.title : t.ask.titleMany({ n: questions.length })}
      navigation={props.navigation}
      error={props.error}
      deadlineMs={params.deadlineMs}
      selectable
      actions={
        <>
          <TextButton disabled={props.busy} onClick={() => props.onSubmit(askChat)}>
            {t.ask.chat}
          </TextButton>
          <TextButton disabled={props.busy} onClick={() => props.onCancel()}>
            {t.common.cancel}
          </TextButton>
          <FilledButton
            disabled={props.busy || !askComplete(answers())}
            onClick={() => props.onSubmit(askSubmit(questions, draft.ask))}
          >
            {t.requests.submit}
          </FilledButton>
        </>
      }
    >
      <div class="ask-form">
        <For each={questions}>
          {(question, index) => (
            <QuestionForm
              question={question}
              answer={answers()[index()] as AskDraft}
              enabled={!props.busy}
              onChange={(update) => change(index(), update)}
            />
          )}
        </For>
      </div>
    </RequestFrame>
  );
}

function QuestionForm(props: {
  readonly question: AskQuestion;
  readonly answer: AskDraft;
  readonly enabled: boolean;
  readonly onChange: (update: (question: AskQuestion, answer: AskDraft) => AskDraft) => void;
}) {
  return (
    <div class="ask-form-question">
      <Show when={props.question.header}>{(header) => <span class="ask-form-header">{header()}</span>}</Show>
      {/* Markdown, as omp's ask dialog renders the question; its links open. */}
      <TranscriptMarkdown text={props.question.question} class="ask-form-question-text" />
      <ChoiceHint
        multi={props.question.multi}
        count={props.answer.selected.length + (props.answer.other && props.answer.custom.trim().length > 0 ? 1 : 0)}
      />
      <ChoiceOptions multi={props.question.multi}>
        <For each={props.question.options}>
          {(option, index) => (
            <ChoiceRow
              multi={props.question.multi}
              chosen={props.answer.selected.includes(option.label)}
              enabled={props.enabled}
              onChoose={() => props.onChange((question, answer) => askChoose(question, answer, option.label))}
              title={
                <>
                  <span>{option.label}</span>
                  <Show when={index() === props.question.recommended}>
                    <span class="ask-form-recommended">{t.ask.recommended}</span>
                  </Show>
                </>
              }
            >
              <Show when={option.description}>
                {(description) => <span class="ask-form-option-subtitle">{description()}</span>}
              </Show>
              <Show when={props.answer.selected.includes(option.label) && option.preview}>
                {(preview) => <span class="ask-form-preview code-style">{preview()}</span>}
              </Show>
            </ChoiceRow>
          )}
        </For>
        <OtherRow
          multi={props.question.multi}
          chosen={props.answer.other}
          enabled={props.enabled}
          text={props.answer.custom}
          onChoose={() => props.onChange(askChooseOther)}
          onInput={(text) => props.onChange((question, answer) => askTypeOther(question, answer, text))}
        />
      </ChoiceOptions>
      <TextField
        class="ask-form-note"
        value={props.answer.note}
        hint={t.ask.note}
        disabled={!props.enabled}
        onInput={(note) => props.onChange((_, answer) => ({ ...answer, note }))}
      />
    </div>
  );
}

/**
 * Under a question: `Choose one`, or for a multi-choice one `Choose any number` and, once any is chosen, how many.
 * Shared with the HTML form (ask_html_form.tsx), as are the option rows below.
 */
export function ChoiceHint(props: { readonly multi: boolean; readonly count: number }) {
  return (
    <span class="ask-form-hint">
      <Show when={props.multi} fallback={t.ask.single}>
        {t.ask.multi}
        <Show when={props.count > 0}>
          <span class="ask-form-hint-dot">{" · "}</span>
          <span class="ask-form-hint-count">{t.ask.chosen({ n: props.count })}</span>
        </Show>
      </Show>
    </span>
  );
}

/** A question's options: one track for a single choice, a tile each for a multi-choice question. */
export function ChoiceOptions(props: {
  readonly multi: boolean;
  /** The question, for assistive technology. */
  readonly label?: string;
  readonly children: JSX.Element;
}) {
  return (
    <div
      class={["ask-form-options", props.multi ? "ask-form-options-multi" : "ask-form-options-single"]}
      role={props.multi ? "group" : "radiogroup"}
      aria-label={props.label}
    >
      {props.children}
    </div>
  );
}

/** An option as a control of its own: a press anywhere on it chooses it, or toggles it in a multi-choice question. */
export function ChoiceRow(props: {
  readonly multi: boolean;
  readonly chosen: boolean;
  readonly enabled: boolean;
  readonly onChoose: () => void;
  readonly title: JSX.Element;
  /** Lines under the title: a description, a preview. */
  readonly children?: JSX.Element;
}) {
  return (
    <button
      type="button"
      role={props.multi ? "checkbox" : "radio"}
      aria-checked={props.chosen ? "true" : "false"}
      data-ripple={props.enabled}
      class={["ask-form-option", { "ask-form-option-chosen": props.chosen }]}
      disabled={!props.enabled}
      onClick={() => props.onChoose()}
    >
      <OptionMark multi={props.multi} chosen={props.chosen} />
      <span class="ask-form-option-text">
        <span class="ask-form-option-title">{props.title}</span>
        {props.children}
      </span>
    </button>
  );
}

/**
 * "Other": an option whose label is a field. Not a button like the others: a button takes Space and Enter as a press,
 * so a field inside one would never get a space typed on a keyboard. Choosing it focuses the field, as typing it is
 * what comes next.
 */
export function OtherRow(props: {
  readonly multi: boolean;
  readonly chosen: boolean;
  readonly enabled: boolean;
  readonly text: string;
  readonly onChoose: () => void;
  readonly onInput: (text: string) => void;
}) {
  let input: HTMLInputElement | undefined;
  return (
    <div
      class={[
        "ask-form-option",
        "ask-form-other",
        { "ask-form-option-chosen": props.chosen, "ask-form-option-disabled": !props.enabled },
      ]}
    >
      <button
        type="button"
        role={props.multi ? "checkbox" : "radio"}
        aria-checked={props.chosen ? "true" : "false"}
        aria-label={t.ask.otherHint}
        class="ask-form-other-mark"
        disabled={!props.enabled}
        onClick={() => {
          const choosing = props.multi ? !props.chosen : true;
          props.onChoose();
          if (choosing) input?.focus();
        }}
      >
        <OptionMark multi={props.multi} chosen={props.chosen} />
      </button>
      <input
        ref={(element) => {
          input = element;
        }}
        class="ask-form-other-input"
        type="text"
        value={props.text}
        placeholder={t.ask.otherHint}
        disabled={!props.enabled}
        spellcheck="false"
        autocomplete="off"
        onInput={(event) => props.onInput(event.currentTarget.value)}
      />
    </div>
  );
}

function OptionMark(props: { readonly multi: boolean; readonly chosen: boolean }) {
  return (
    <span class="ask-form-mark">
      <Show when={props.multi} fallback={<RadioMark selected={props.chosen} />}>
        <CheckboxMark checked={props.chosen} />
      </Show>
    </span>
  );
}
