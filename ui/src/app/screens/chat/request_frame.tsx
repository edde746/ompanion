// Port of lib/screens/chat/request_frame.dart.
import type { JSX } from "@solidjs/web";
import { createSignal, onSettled, Show } from "solid-js";
import { t } from "../../i18n/i18n";
import "./request_frame.css";

/** The body's bottom fade, in CSS px; a focused field scrolls clear of it. */
const fadeHeight = 24;

/**
 * One inline request: title with the open-request count and navigation, a scrollable body, the countdown, an error line
 * and the actions. A flat block docked above the composer; it never covers anything.
 *
 * The body fades out at its bottom edge while more of it is below. The actions stay one row, at the end, while they fit
 * on one; else they stack into a column of full-width buttons with the filled one on top.
 */
export function RequestFrame(props: {
  readonly title: string;
  readonly children: JSX.Element;
  readonly actions: JSX.Element;
  /** The "2 of 3" count with previous and next, when more than one request is open. */
  readonly navigation?: JSX.Element;
  /** Epoch ms at which omp stops waiting for the answer. */
  readonly deadlineMs?: number;
  readonly error?: string;
  /** The body's text can be selected, as Flutter's SelectionArea. */
  readonly selectable?: boolean;
}) {
  let body: HTMLDivElement | undefined;
  let actions: HTMLDivElement | undefined;
  const [more, setMore] = createSignal(false);

  const measureBody = () => {
    if (body === undefined) return;
    setMore(body.scrollTop + body.clientHeight < body.scrollHeight - 1);
  };
  /** Scrolls the focused field (with its filled box) fully into the body, above the fade. */
  const reveal = (target: Element) => {
    if (body === undefined || !body.contains(target)) return;
    const shown = body.getBoundingClientRect();
    const field = (target.closest("label") ?? target).getBoundingClientRect();
    const below = field.bottom - (shown.bottom - fadeHeight);
    if (below > 0) body.scrollTop += Math.min(below, field.top - shown.top);
    else if (field.top < shown.top) body.scrollTop -= shown.top - field.top;
  };
  // Measured, not wrapped by CSS: a wrapped row leaves one button alone on a line of its own.
  const stackActions = () => {
    if (actions === undefined) return;
    const first = actions.firstElementChild;
    if (first === null) return;
    actions.classList.remove("request-frame-actions-stacked");
    // In one row the buttons pack at the end; ones that do not fit push the first past the row's start.
    const overflows = first.getBoundingClientRect().left < actions.getBoundingClientRect().left - 0.5;
    actions.classList.toggle("request-frame-actions-stacked", overflows);
  };

  onSettled(() => {
    const bodyElement = body;
    const actionsElement = actions;
    if (bodyElement === undefined || actionsElement === undefined) return;
    // The body's contents grow and shrink (a chosen option's preview, the keyboard taking the window's height).
    const bodyObserver = new ResizeObserver(() => {
      measureBody();
      const focused = document.activeElement;
      if (focused !== null) reveal(focused);
    });
    bodyObserver.observe(bodyElement);
    for (const child of bodyElement.children) bodyObserver.observe(child);
    const actionsObserver = new ResizeObserver(stackActions);
    actionsObserver.observe(actionsElement);
    for (const child of actionsElement.children) actionsObserver.observe(child);
    return () => {
      bodyObserver.disconnect();
      actionsObserver.disconnect();
    };
  });

  return (
    <div class="request-frame">
      <div class="request-frame-title-row">
        <span class="request-frame-title">{props.title}</span>
        <Show when={props.deadlineMs}>{(deadlineMs) => <Countdown untilMs={deadlineMs()} />}</Show>
        {props.navigation}
      </div>
      <div
        ref={(element) => {
          body = element;
        }}
        class={["request-frame-body", { "request-frame-selectable": props.selectable, "request-frame-more": more() }]}
        onScroll={measureBody}
        onFocusIn={(event) => {
          if (event.target instanceof Element) reveal(event.target);
        }}
      >
        {props.children}
      </div>
      <Show when={props.error}>{(error) => <p class="request-frame-error">{error()}</p>}</Show>
      <div
        ref={(element) => {
          actions = element;
        }}
        class="request-frame-actions"
      >
        {props.actions}
      </div>
    </div>
  );
}

/** "12 s left", updated every second. */
function Countdown(props: { readonly untilMs: number }) {
  const [nowMs, setNowMs] = createSignal(Date.now());
  onSettled(() => {
    const timer = setInterval(() => setNowMs(Date.now()), 1000);
    return () => clearInterval(timer);
  });
  return (
    <span class="request-frame-countdown">
      {t.requests.secondsLeft({ n: Math.max(0, Math.ceil((props.untilMs - nowMs()) / 1000)) })}
    </span>
  );
}
