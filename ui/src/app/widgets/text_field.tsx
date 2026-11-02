// The theme's TextField: a filled, borderless field one control tall (rules 1 and 4). Labels go above it
// (LabeledField); the placeholder is a hint, never a floating label.
import type { JSX } from "@solidjs/web";
import { Show } from "solid-js";
import { Icon } from "./icon";
import "./text_field.css";

export interface TextFieldProps {
  readonly value: string;
  readonly onInput: (value: string) => void;
  /** Enter in a one-line field. */
  readonly onSubmit?: (value: string) => void;
  readonly onKeyDown?: (event: KeyboardEvent) => void;
  readonly onFocus?: (event: FocusEvent) => void;
  readonly onBlur?: (event: FocusEvent) => void;
  readonly hint?: string;
  /** A glyph before the text, in onSurfaceVariant. */
  readonly prefixIcon?: string;
  /** A control at the end, e.g. a clear or browse button. */
  readonly suffix?: JSX.Element;
  readonly type?: "text" | "password" | "search" | "url" | "email" | "number";
  readonly disabled?: boolean;
  readonly autofocus?: boolean;
  /** Code, paths and keys: in the code font. */
  readonly code?: boolean;
  readonly enterKeyHint?: "search" | "done" | "go" | "next" | "send";
  readonly class?: string;
  readonly ref?: (element: HTMLInputElement) => void;
}

export function TextField(props: TextFieldProps) {
  return (
    <label class={["text-field", { "text-field-disabled": props.disabled }, props.class]}>
      <Show when={props.prefixIcon}>
        {(icon) => (
          <span class="text-field-prefix">
            <Icon icon={icon()} size={18} />
          </span>
        )}
      </Show>
      <input
        class={["text-field-input", { "text-field-code": props.code }]}
        type={props.type ?? "text"}
        value={props.value}
        placeholder={props.hint}
        disabled={props.disabled}
        autofocus={props.autofocus}
        enterkeyhint={props.enterKeyHint}
        spellcheck={false}
        autocomplete="off"
        onInput={(event) => props.onInput(event.currentTarget.value)}
        onKeyDown={(event) => {
          props.onKeyDown?.(event);
          if (event.key === "Enter" && !event.isComposing && !event.defaultPrevented) {
            props.onSubmit?.(event.currentTarget.value);
          }
        }}
        onFocus={(event) => props.onFocus?.(event)}
        onBlur={(event) => props.onBlur?.(event)}
        ref={props.ref}
      />
      <Show when={props.suffix}>
        <span class="text-field-suffix">{props.suffix}</span>
      </Show>
    </label>
  );
}
