// Modal dialogs (docs/design.md rule 5, Components "Modal dialog"): only short, user-initiated confirmations and the
// new-session form. A surfaceContainer sheet with `sheetRadius` over a black scrim, 80 % in a dark theme and 50 % in a
// light one, so a dialog opened from a dialog stands apart from it. The content scrolls, so a form still fits above
// the on-screen keyboard on a short display (rule 13). Dialogs fade in and out as Material's DialogRoute does.
import type { JSX } from "@solidjs/web";
import { createEffect, createSignal, For, onSettled, Show } from "solid-js";
import { type Deferred, deferred } from "../../deferred";
import { Curves, curveFrames, play, settled } from "../motion";
import { onBack } from "../platform";
import { Icon } from "./icon";
import "./dialog.css";

export interface DialogProps {
  /** A Symbols glyph above the title, which then centres, as in Material 3's AlertDialog. */
  readonly icon?: string;
  /** A CSS colour for {@link icon}; Material 3's default is the scheme's secondary. */
  readonly iconColor?: string;
  readonly title?: string;
  readonly children?: JSX.Element;
  /** The buttons at the end: TextButtons, the primary one a FilledButton. */
  readonly actions?: JSX.Element;
  readonly class?: string;
}

/** Material's AlertDialog in the theme: icon, title, scrolling content, actions. */
export function Dialog(props: DialogProps) {
  let actions: HTMLDivElement | undefined;
  // Flutter's OverflowBar: the actions in one row while they fit, else each on its own line at the end.
  onSettled(() => {
    const fit = () => {
      if (!actions) return;
      actions.classList.remove("dialog-actions-stacked");
      // Their own widths, not scrollWidth: a row packed at the end overflows to the left, which does not scroll.
      const buttons = [...actions.children];
      const gap = Number.parseFloat(getComputedStyle(actions).columnGap) || 0;
      const needed = buttons.reduce((sum, button) => sum + button.getBoundingClientRect().width, 0);
      if (needed + gap * (buttons.length - 1) > actions.clientWidth) actions.classList.add("dialog-actions-stacked");
    };
    fit();
    window.addEventListener("resize", fit);
    return () => window.removeEventListener("resize", fit);
  });
  return (
    <div
      class={["dialog", { "dialog-with-icon": props.icon !== undefined }, props.class]}
      role="dialog"
      aria-modal="true"
      aria-label={props.title}
    >
      <Show when={props.icon}>
        {(icon) => (
          <span class="dialog-icon" style={{ color: props.iconColor }}>
            <Icon icon={icon()} size={24} />
          </span>
        )}
      </Show>
      <Show when={props.title}>{(title) => <h2 class="dialog-title">{title()}</h2>}</Show>
      <Show when={props.children}>
        <div class="dialog-content">{props.children}</div>
      </Show>
      <Show when={props.actions}>
        <div class="dialog-actions" ref={actions}>
          {props.actions}
        </div>
      </Show>
    </div>
  );
}

interface Shown {
  readonly build: (close: (value?: unknown) => void) => JSX.Element;
  readonly dismissible: () => boolean;
  readonly done: Deferred<unknown>;
}

/** The open dialogs, the top one last. */
const [stack, setStack] = createSignal<readonly Shown[]>([]);
/** The dialogs on screen: the open ones, and closed ones until they have faded out. */
const [layers, setLayers] = createSignal<readonly Shown[]>([]);

function closeDialog(shown: Shown, value: unknown): void {
  if (!stack().includes(shown)) return;
  setStack((list) => list.filter((entry) => entry !== shown));
  shown.done.resolve(value);
}

/**
 * Shows the dialog `build` returns (usually a {@link Dialog}) over the app; resolves with what it passed to `close`, or
 * undefined when dismissed by a tap on the scrim, Escape or back, unless `dismissible` is false. A function is asked at
 * each attempt, as Flutter's PopScope(canPop:) is: a form refuses while it submits.
 */
export function showDialog<T>(
  build: (close: (value?: T) => void) => JSX.Element,
  options: { readonly dismissible?: boolean | (() => boolean) } = {},
): Promise<T | undefined> {
  const done = deferred<unknown>();
  const dismissible = options.dismissible ?? true;
  const shown: Shown = {
    build: (close) => build((value) => close(value)),
    dismissible: typeof dismissible === "function" ? dismissible : () => dismissible,
    done,
  };
  setStack((list) => [...list, shown]);
  setLayers((list) => [...list, shown]);
  return done.promise as Promise<T | undefined>;
}

/** DialogRoute's transitionDuration (material/dialog.dart). */
const fadeMs = 150;

/**
 * One dialog over its scrim. It fades in over 150 ms on easeOut (DialogRoute's FadeTransition) while the scrim fades
 * in on ease (ModalRoute's barrierCurve); closing plays both backwards, the layer inert, and it leaves once they end.
 */
function DialogLayer(props: { readonly shown: Shown }) {
  let layer!: HTMLDivElement;
  let scrim!: HTMLDivElement;
  let before: Element | null = null;
  let fades: Animation[] = [];
  const close = (value?: unknown) => closeDialog(props.shown, value);
  const dismiss = () => {
    if (props.shown.dismissible()) close(undefined);
  };
  const top = () => stack()[stack().length - 1] === props.shown;

  onSettled(() => {
    before = document.activeElement;
    // A field takes the focus; otherwise the layer does, as Flutter focuses the route and no button: a button
    // focused on open would show its focus tone after a keyboard shortcut. Tab reaches the buttons.
    const field = layer.querySelector<HTMLElement>("[autofocus], input, textarea, select");
    (field ?? layer).focus();
    const content = [...layer.children].filter((child) => child !== scrim);
    fades = [
      play(scrim, curveFrames(Curves.ease, (value) => ({ opacity: value })), fadeMs),
      ...content.map((child) => play(child, curveFrames(Curves.easeOut, (value) => ({ opacity: value })), fadeMs)),
    ];
  });

  createEffect(
    () => stack().includes(props.shown),
    (open) => {
      if (open) return onBack(dismiss);
      if (before instanceof HTMLElement && before.isConnected) before.focus();
      for (const fade of fades) fade.reverse();
      const shown = props.shown;
      void Promise.all(fades.map(settled)).then(() => setLayers((list) => list.filter((entry) => entry !== shown)));
    },
  );

  return (
    <div
      class="dialog-layer"
      ref={layer}
      tabindex="-1"
      inert={!top()}
      aria-hidden={stack().includes(props.shown) ? undefined : "true"}
      onKeyDown={(event) => {
        if (event.key !== "Escape") return;
        event.preventDefault();
        dismiss();
      }}
    >
      <div class="dialog-scrim" ref={scrim} onPointerDown={dismiss} />
      {props.shown.build(close)}
    </div>
  );
}

/** Shows the dialogs; the app renders one. */
export function DialogHost() {
  return <For each={layers()}>{(shown) => <DialogLayer shown={shown} />}</For>;
}

/** Whether a dialog is open: the app's shortcuts stay off meanwhile. */
export function dialogOpen(): boolean {
  return stack().length > 0;
}
