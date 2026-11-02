// lib/widgets/app_search_field.dart.
import { createSignal, onSettled, Show } from "solid-js";
import { materialLocalizations } from "../i18n/material_localizations";
import { IconButton } from "./button";
import { SearchDebounce } from "./search_debounce";
import * as Symbols from "./symbols";
import { TextField } from "./text_field";

export interface AppSearchFieldProps {
  readonly onChanged: (query: string) => void;
  readonly hint?: string;
  /** The text the field starts with. */
  readonly initial?: string;
  readonly debounceMs?: number;
  readonly onSubmitted?: (query: string) => void;
  readonly onKeyDown?: (event: KeyboardEvent) => void;
  readonly onBlur?: (event: FocusEvent) => void;
  readonly autofocus?: boolean;
  readonly class?: string;
  readonly ref?: (element: HTMLInputElement) => void;
}

/**
 * Search that filters as you type: `onChanged` fires 250 ms after the last keystroke, at once on Enter and on clear.
 * No separate search button (docs/design.md rule 7).
 */
export function AppSearchField(props: AppSearchFieldProps) {
  const [text, setText] = createSignal(props.initial ?? "");
  const queries = new SearchDebounce(
    (query) => props.onChanged(query),
    () => props.debounceMs ?? 250,
  );
  let input: HTMLInputElement | undefined;

  onSettled(() => () => queries.dispose());

  function changed(value: string) {
    setText(value);
    queries.typed(value);
  }

  return (
    <TextField
      class={props.class}
      type="search"
      enterKeyHint="search"
      value={text()}
      hint={props.hint}
      prefixIcon={Symbols.search}
      autofocus={props.autofocus}
      onInput={changed}
      onSubmit={(value) => {
        queries.now(value);
        props.onSubmitted?.(value);
      }}
      onKeyDown={(event) => props.onKeyDown?.(event)}
      onBlur={(event) => props.onBlur?.(event)}
      ref={(element) => {
        input = element;
        props.ref?.(element);
      }}
      suffix={
        <Show when={text() !== ""}>
          <IconButton
            icon={Symbols.close}
            iconSize={16}
            size={32}
            tooltip={materialLocalizations().clearButtonTooltip}
            onClick={() => {
              setText("");
              queries.now("");
              input?.focus();
            }}
          />
        </Show>
      }
    />
  );
}
