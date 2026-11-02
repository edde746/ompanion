// lib/widgets/labeled_field.dart.
import type { JSX } from "@solidjs/web";
import { Show } from "solid-js";
import "./labeled_field.css";

export interface LabeledFieldProps {
  readonly label: string;
  readonly children: JSX.Element;
  /** Shown under the control, for controls without an error line of their own. */
  readonly error?: string;
}

/**
 * A control with its label above it: a `labelMedium` label in onSurfaceVariant, 4 px, the control. Filled fields do not
 * float their label inside the fill: at one control height it would sit against the top edge.
 */
export function LabeledField(props: LabeledFieldProps) {
  return (
    <div class="labeled-field">
      <span class="labeled-field-label">{props.label}</span>
      {props.children}
      <Show when={props.error}>{(error) => <span class="labeled-field-error">{error()}</span>}</Show>
    </div>
  );
}
