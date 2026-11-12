// The companion's `form` request, inline: omp's `ask` from 18.18.3 asks with one HTML form, which omp parsed on the
// host (html_form.ts). Its choices draw as the question-based ask form's do (ask_form.tsx).
import type { JSX } from "@solidjs/web";
import { createMemo, createSignal, For, Match, Show, Switch, untrack } from "solid-js";
import { FormatException, type JsonObject } from "../../../core/rpc/json_fields";
import { t } from "../../i18n/i18n";
import { AppSelect } from "../../widgets/app_select";
import { FilledButton, TextButton } from "../../widgets/button";
import { showImageViewer } from "../../widgets/image_viewer";
import { TextField, type TextFieldProps } from "../../widgets/text_field";
import { ChoiceHint, ChoiceOptions, ChoiceRow, OtherRow } from "./ask_form";
import "./ask_html_form.css";
import {
  chooseOption,
  chooseOther,
  chosenCount,
  type FieldDraft,
  type FieldError,
  type FormBlock,
  type FormChoice,
  type FormInput,
  type FormSpan,
  type HtmlForm,
  htmlFormDrafts,
  htmlFormErrors,
  htmlFormFromJson,
  htmlFormSubmit,
  spansText,
  typeOther,
} from "./html_form";
import { RequestFrame } from "./request_frame";
import type { RequestDraft } from "./requests";
import "./transcript/code_style.css";

/** A field's change: the next draft from its current one. */
type FieldUpdate = (draft: FieldDraft) => FieldDraft;

/**
 * The form's sections in document order: each `<fieldset>`'s legend over its text, lists, tables, preformatted text,
 * pictures and fields. Submit checks every field by omp's rules first and shows what fails under each field.
 */
export function AskHtmlForm(props: {
  readonly params: { readonly [key: string]: unknown };
  /** Holds the field drafts so far: empty the first time, filled and kept up to date here. */
  readonly draft: RequestDraft;
  readonly busy: boolean;
  readonly error?: string;
  /** Called with the `form` answer value (`{kind: "submit", data}`). */
  readonly onSubmit: (answer: JsonObject) => void;
  /** Cancels the request, which aborts the turn as Esc does in the TUI. */
  readonly onCancel: () => void;
  readonly navigation?: JSX.Element;
}) {
  const draft = untrack(() => props.draft);
  let form: HtmlForm;
  try {
    form = htmlFormFromJson(untrack(() => props.params));
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
  if (draft.form.length === 0) draft.form = htmlFormDrafts(form);
  const [answers, setAnswers] = createSignal(draft.form);
  // Errors show once Submit found one, then follow every change.
  const [checked, setChecked] = createSignal(false);
  const errors = createMemo(() => (checked() ? htmlFormErrors(form, answers()) : []));
  const fieldIndex = new Map(form.fields.map((field, index) => [field, index] as const));
  let body: HTMLDivElement | undefined;
  // The draft is the source of truth: a signal read in a handler returns its last committed value.
  const change = (index: number, update: FieldUpdate) => {
    draft.form = draft.form.map((answer, at) => (at === index ? update(answer) : answer));
    setAnswers(draft.form);
  };
  const submit = () => {
    const first = htmlFormErrors(form, draft.form).findIndex((error) => error !== undefined);
    if (first < 0) {
      props.onSubmit(htmlFormSubmit(form, draft.form));
      return;
    }
    setChecked(true);
    body?.querySelector(`[data-field="${first}"]`)?.scrollIntoView({ block: "nearest" });
  };
  return (
    <RequestFrame
      title={t.ask.title}
      navigation={props.navigation}
      error={props.error}
      deadlineMs={form.deadlineMs}
      selectable
      actions={
        <>
          <TextButton disabled={props.busy} onClick={() => props.onCancel()}>
            {t.common.cancel}
          </TextButton>
          <FilledButton disabled={props.busy} onClick={submit}>
            {t.requests.submit}
          </FilledButton>
        </>
      }
    >
      <div
        class="ask-html-form"
        ref={(element) => {
          body = element;
        }}
      >
        <For each={form.sections}>
          {(section) => (
            <section class="ask-html-form-section">
              <Show when={section.title.length > 0}>
                <Spans class="ask-html-form-title" spans={section.title} />
              </Show>
              <For each={section.blocks}>
                {(block) => {
                  if (block.kind !== "choice" && block.kind !== "input") return <ContentBlock block={block} />;
                  // The fields are these blocks themselves, so every one has its index.
                  const index = fieldIndex.get(block)!;
                  const onChange = (update: FieldUpdate) => change(index, update);
                  return block.kind === "choice" ? (
                    <ChoiceField
                      field={block}
                      draft={answers()[index]!}
                      error={errors()[index]}
                      enabled={!props.busy}
                      index={index}
                      onChange={onChange}
                    />
                  ) : (
                    <InputField
                      field={block}
                      draft={answers()[index]!}
                      error={errors()[index]}
                      enabled={!props.busy}
                      index={index}
                      onChange={onChange}
                    />
                  );
                }}
              </For>
            </section>
          )}
        </For>
      </div>
    </RequestFrame>
  );
}

/** Inline text in its emphasis; a `"\n"` breaks the line. */
function Spans(props: { readonly spans: readonly FormSpan[]; readonly class?: string }) {
  return (
    <span class={["ask-html-form-spans", props.class]}>
      <For each={props.spans}>
        {(span) => (
          <Switch fallback={span.text}>
            <Match when={span.style === "code"}>
              <code class="ask-html-form-code">{span.text}</code>
            </Match>
            <Match when={span.style === "strong"}>
              <strong>{span.text}</strong>
            </Match>
            <Match when={span.style === "em"}>
              <em>{span.text}</em>
            </Match>
          </Switch>
        )}
      </For>
    </span>
  );
}

function ContentBlock(props: { readonly block: Exclude<FormBlock, FormChoice | FormInput> }) {
  const block = props.block;
  switch (block.kind) {
    case "text":
      return (
        <p class={["ask-html-form-text", { "ask-html-form-heading": block.heading }]}>
          <Spans spans={block.spans} />
        </p>
      );
    case "list": {
      const items = (
        <For each={block.items}>
          {(item) => (
            <li>
              <Spans spans={item} />
            </li>
          )}
        </For>
      );
      return block.ordered ? <ol class="ask-html-form-list">{items}</ol> : <ul class="ask-html-form-list">{items}</ul>;
    }
    case "pre":
      return <pre class="ask-html-form-pre code-style">{block.text}</pre>;
    case "table":
      return (
        <div class="ask-html-form-table-scroll">
          <table class="ask-html-form-table">
            <tbody>
              <For each={block.rows}>
                {(row, rowIndex) => (
                  <tr>
                    <For each={row}>
                      {(cell) =>
                        rowIndex() < block.headerRows ? (
                          <th>
                            <Spans spans={cell} />
                          </th>
                        ) : (
                          <td>
                            <Spans spans={cell} />
                          </td>
                        )
                      }
                    </For>
                  </tr>
                )}
              </For>
            </tbody>
          </table>
        </div>
      );
    case "image":
      return (
        <Show
          when={block.uri}
          fallback={
            <Show when={block.alt}>{(alt) => <p class="ask-html-form-text ask-html-form-missing">{alt()}</p>}</Show>
          }
        >
          {(uri) => (
            <button
              type="button"
              class="ask-html-form-picture"
              aria-label={block.alt}
              onClick={() => void showImageViewer(dataUriBytes(uri()))}
            >
              <img class="ask-html-form-image" src={uri()} alt={block.alt} />
            </button>
          )}
        </Show>
      );
  }
}

/** The bytes of a base64 `data:` URI, as the companion sends pictures. */
function dataUriBytes(uri: string): Uint8Array {
  const base64 = uri.slice(uri.indexOf(",") + 1);
  return Uint8Array.from(atob(base64), (char) => char.charCodeAt(0));
}

interface FieldProps {
  readonly draft: FieldDraft;
  readonly error: FieldError | undefined;
  readonly enabled: boolean;
  /** The field's position, marked on its element, so Submit can scroll to the first field that fails. */
  readonly index: number;
  readonly onChange: (update: FieldUpdate) => void;
}

/**
 * A radio or checkbox group as the question-based form's options, "Other" with them where the form adds it; a single
 * `<select>` as the app's select; a lone checkbox as one tile.
 */
function ChoiceField(props: FieldProps & { readonly field: FormChoice }) {
  const choice = () => (props.draft.kind === "choice" ? props.draft : undefined);
  return (
    <div class="ask-html-form-field" data-field={props.index}>
      <Show when={props.field.label.length > 0}>
        <Spans class="ask-html-form-label" spans={props.field.label} />
      </Show>
      <Show
        when={props.field.select && !props.field.multi}
        fallback={
          <>
            <Show when={props.field.options.length > 1}>
              <ChoiceHint multi={props.field.multi} count={chosenCount(props.draft)} />
            </Show>
            <ChoiceOptions multi={props.field.multi} label={props.field.question}>
              <For each={props.field.options}>
                {(option, index) => (
                  <ChoiceRow
                    multi={props.field.multi}
                    chosen={choice()?.checked.includes(index()) ?? false}
                    enabled={props.enabled && !option.disabled}
                    onChoose={() => props.onChange((draft) => chooseOption(props.field, draft, index()))}
                    title={<Spans spans={option.label} />}
                  />
                )}
              </For>
              <Show when={props.field.other}>
                <OtherRow
                  multi={props.field.multi}
                  chosen={choice()?.other ?? false}
                  enabled={props.enabled}
                  text={choice()?.otherText ?? ""}
                  onChoose={() => props.onChange((draft) => chooseOther(props.field, draft))}
                  onInput={(text) => props.onChange((draft) => typeOther(props.field, draft, text))}
                />
              </Show>
            </ChoiceOptions>
          </>
        }
      >
        <div class="ask-html-form-select">
          <AppSelect
            value={choice()?.checked[0] ?? 0}
            options={props.field.options.flatMap((option, index) =>
              option.disabled ? [] : [[index, spansText(option.label)] as const],
            )}
            tooltip={props.field.question}
            expand
            disabled={!props.enabled}
            onChanged={(index) => props.onChange((draft) => chooseOption(props.field, draft, index))}
          />
        </div>
      </Show>
      <ErrorLine error={props.error} />
    </div>
  );
}

/** omp checks `email`, `url` and numbers itself; other types (`date`, `tel`, …) take their text as typed. */
function inputType(type: string): TextFieldProps["type"] {
  switch (type) {
    case "number":
    case "range":
      return "number";
    case "email":
    case "url":
    case "password":
    case "search":
      return type;
    default:
      return "text";
  }
}

function InputField(props: FieldProps & { readonly field: FormInput }) {
  const text = () => (props.draft.kind === "input" ? props.draft.text : "");
  const onInput = (value: string) =>
    props.onChange((draft) => (draft.kind === "input" ? { ...draft, text: value } : draft));
  return (
    <div class="ask-html-form-field" data-field={props.index}>
      <Spans class="ask-html-form-label" spans={props.field.label} />
      <Show
        when={props.field.multiline}
        fallback={
          <TextField
            type={inputType(props.field.type)}
            value={text()}
            hint={props.field.placeholder || undefined}
            disabled={!props.enabled}
            onInput={onInput}
          />
        }
      >
        <textarea
          class="ask-html-form-textarea"
          rows={Math.min(Math.max(props.field.rows, 2), 12)}
          value={text()}
          placeholder={props.field.placeholder || undefined}
          aria-label={props.field.question}
          disabled={!props.enabled}
          spellcheck="false"
          onInput={(event) => onInput(event.currentTarget.value)}
        />
      </Show>
      <ErrorLine error={props.error} />
    </div>
  );
}

function ErrorLine(props: { readonly error: FieldError | undefined }) {
  return <Show when={props.error}>{(error) => <span class="ask-html-form-error">{errorText(error())}</span>}</Show>;
}

function errorText(error: FieldError): string {
  switch (error.kind) {
    case "required":
      return t.ask.errors.required;
    case "chooseOne":
      return t.ask.errors.chooseOne;
    case "number":
      return t.ask.errors.number;
    case "min":
      return t.ask.errors.min({ min: error.min });
    case "max":
      return t.ask.errors.max({ max: error.max });
    case "minLength":
      return t.ask.errors.minLength({ n: error.length });
    case "maxLength":
      return t.ask.errors.maxLength({ n: error.length });
    case "email":
      return t.ask.errors.email;
    case "url":
      return t.ask.errors.url;
    case "pattern":
      return t.ask.errors.pattern({
        pattern: error.pattern.length > 40 ? `${error.pattern.slice(0, 39)}…` : error.pattern,
      });
  }
}
