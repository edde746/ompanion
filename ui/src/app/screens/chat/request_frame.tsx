// Port of lib/screens/chat/request_frame.dart.
import type { JSX } from "@solidjs/web";
import { createSignal, onSettled, Show } from "solid-js";
import { t } from "../../i18n/i18n";
import "./request_frame.css";

/**
 * One inline request: title with the open-request count and navigation, a scrollable body, the countdown, an error line
 * and the actions. A flat block docked above the composer; it never covers anything.
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
  return (
    <div class="request-frame">
      <div class="request-frame-title-row">
        <span class="request-frame-title">{props.title}</span>
        <Show when={props.deadlineMs}>{(deadlineMs) => <Countdown untilMs={deadlineMs()} />}</Show>
        {props.navigation}
      </div>
      <div class={["request-frame-body", { "request-frame-selectable": props.selectable }]}>{props.children}</div>
      <Show when={props.error}>{(error) => <p class="request-frame-error">{error()}</p>}</Show>
      <div class="request-frame-actions">{props.actions}</div>
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
