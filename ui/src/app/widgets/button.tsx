// The theme's buttons (lib/app/theme.dart, docs/design.md Components): FilledButton for the primary action, its tonal
// form for secondary ones, TextButton for low emphasis, IconButton for icon-only actions. Every inline button is one
// control tall (rule 4).
import type { JSX } from "@solidjs/web";
import { Show } from "solid-js";
import "./button.css";
import { Icon } from "./icon";
// Every screen shows a button, so the ripple's listeners install from here.
import "./ripple";
import { tooltip } from "./tooltip";

export interface ButtonProps {
  readonly children?: JSX.Element;
  /** A leading icon, as `FilledButton.icon`. */
  readonly icon?: string;
  readonly onClick?: (event: MouseEvent) => void;
  readonly disabled?: boolean;
  /** Fixed per button: a button gets a tooltip when it is created with one. */
  readonly tooltip?: string;
  readonly type?: "button" | "submit";
  readonly class?: string;
  readonly ref?: (element: HTMLButtonElement) => void;
}

function ButtonBase(props: ButtonProps & { readonly variant: "filled" | "tonal" | "text" }) {
  const refs = [props.ref, props.tooltip === undefined ? undefined : tooltip(() => props.tooltip ?? "")].filter(
    (ref) => ref !== undefined,
  );
  return (
    <button
      type={props.type ?? "button"}
      data-ripple
      class={["button", `button-${props.variant}`, props.class]}
      disabled={props.disabled}
      onClick={(event) => props.onClick?.(event)}
      ref={refs}
    >
      <Show when={props.icon}>{(icon) => <Icon icon={icon()} size={18} />}</Show>
      {props.children}
    </button>
  );
}

/** The primary action: an onSurface fill. */
export function FilledButton(props: ButtonProps) {
  return <ButtonBase {...props} variant="filled" />;
}

/** A secondary action: `FilledButton.tonal`, a surfaceContainerHigh fill. */
export function TonalButton(props: ButtonProps) {
  return <ButtonBase {...props} variant="tonal" />;
}

/** A low-emphasis action: text alone. */
export function TextButton(props: ButtonProps) {
  return <ButtonBase {...props} variant="text" />;
}

export interface IconButtonProps {
  readonly icon: string;
  /** Names the action; also the button's accessible name. */
  readonly tooltip: string;
  readonly onClick?: (event: MouseEvent) => void;
  readonly disabled?: boolean;
  /** standard: onSurfaceVariant on nothing; filled: onPrimary on primary; tonal: on surfaceContainerHigh. */
  readonly variant?: "standard" | "filled" | "tonal";
  /** The square the button takes: 40 px, Material's; compact rows pass less. */
  readonly size?: number;
  readonly iconSize?: number;
  readonly class?: string;
  readonly ref?: (element: HTMLButtonElement) => void;
}

/** Material's IconButton: a round 40 px target with a 24 px glyph. */
export function IconButton(props: IconButtonProps) {
  const refs = [props.ref, tooltip(() => props.tooltip)].filter((ref) => ref !== undefined);
  return (
    <button
      type="button"
      data-ripple
      class={["icon-button", `icon-button-${props.variant ?? "standard"}`, props.class]}
      style={props.size === undefined ? undefined : { width: `${props.size}px`, height: `${props.size}px` }}
      disabled={props.disabled}
      onClick={(event) => props.onClick?.(event)}
      ref={refs}
    >
      <Icon icon={props.icon} size={props.iconSize ?? 24} />
    </button>
  );
}
