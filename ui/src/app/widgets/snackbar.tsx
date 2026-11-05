// ScaffoldMessenger's SnackBar in the theme: inverseSurface with onInverseSurface text and radius `radius`, one at a
// time, each for 4 s from when it is in, in the order they came. It moves as Material 3's floating SnackBar does
// (material/snack_bar.dart): it grows from its bottom edge and fades in, fades out when it times out or its action is
// pressed, and the next one comes in after. A touch can swipe it down and away (Dismissible, direction down).
import { createSignal, onSettled, Show } from "solid-js";
import { Curves, curveFrames, motionScale, play, settled } from "../motion";
import { insets } from "../platform";
import "./snackbar.css";

export interface SnackBarAction {
  readonly label: string;
  readonly onPressed: () => void;
}

interface Bar {
  readonly text: string;
  readonly action?: SnackBarAction;
  readonly durationMs: number;
  readonly error: boolean;
}

const [queue, setQueue] = createSignal<readonly Bar[]>([]);

/**
 * `ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)))`. `error`: the error text on the
 * errorSurface background, as the chat's notices show failures.
 */
export function showSnackBar(
  text: string,
  options: { action?: SnackBarAction; durationMs?: number; error?: boolean } = {},
): void {
  const bar: Bar = {
    text,
    durationMs: options.durationMs ?? 4000,
    error: options.error ?? false,
    ...(options.action ? { action: options.action } : {}),
  };
  setQueue((list) => [...list, bar]);
}

/** Takes the shown bar away, which lets the next one in. */
function remove(bar: Bar): void {
  setQueue((list) => (list[0] === bar ? list.slice(1) : list));
}

/** Shows the snack bars; the app renders one. */
export function SnackBarHost() {
  return (
    <Show when={queue()[0]} keyed>
      {(bar) => <SnackBar bar={bar} />}
    </Show>
  );
}

// snack_bar.dart: _snackBarTransitionDuration, _snackBarM3HeightCurve, _snackBarM3FadeInCurve.
const transitionMs = 250;
const heightCurve = Curves.easeInOutQuart;
const fade = { begin: 0.4, end: 0.6, curve: Curves.easeInCirc };
// widgets/dismissible.dart: movementDuration, _kDismissThreshold, _kMinFlingVelocity, _kMinFlingVelocityDelta;
// gestures/constants.dart: kTouchSlop, where a drag starts.
const moveMs = 200;
const dismissThreshold = 0.4;
const minFlingVelocity = 700;
const minFlingVelocityDelta = 400;
const touchSlop = 18;

interface Drag {
  readonly pointer: number;
  readonly startY: number;
  /** Where the finger was when it passed the slop; the bar follows it from there. */
  baseY?: number;
  /** How far the bar may travel: its height and the gap under it, which it slides through before it is clipped. */
  size: number;
  gap: number;
  extent: number;
  /** The last 100 ms of the finger's way, for its speed when it lifts (VelocityTracker's horizon). */
  readonly samples: { time: number; x: number; y: number }[];
}

/**
 * Where a bar rests when a chat's composer is on screen: 8 px above its block, as Material's floating SnackBar rests
 * above a bottom bar, so it never covers the draft or the send button. Undefined elsewhere: the stylesheet's place.
 */
function restingBottom(): string | undefined {
  for (const block of document.querySelectorAll<HTMLElement>(".composer-block")) {
    if (block.closest("[inert]") !== null) continue;
    const rect = block.getBoundingClientRect();
    if (rect.height > 0 && rect.bottom <= window.innerHeight) return `${window.innerHeight - rect.top + 8}px`;
  }
  return undefined;
}

function SnackBar(props: { readonly bar: Bar }) {
  let element!: HTMLDivElement;
  const bottom = restingBottom();
  let entering: Animation[] = [];
  let timer: ReturnType<typeof setTimeout> | undefined;
  let hiding = false;
  let drag: Drag | undefined;

  // The bar slid `extent` px down, clipped at the bottom of its gap as Flutter's ClipRect clips the Dismissible.
  const slid = (extent: number, gap: number) => ({
    translate: `0 ${extent}px`,
    clipPath: `inset(0 0 ${Math.max(0, extent - gap)}px 0)`,
  });

  onSettled(() => {
    // M3: the height grows from the bottom edge (Align(bottomLeft, heightFactor)) while it fades in over 40–60 %.
    entering = [
      play(
        element,
        curveFrames(heightCurve, (height) => ({ clipPath: `inset(${(1 - height) * 100}% 0 0 0)` })),
        transitionMs,
      ),
      play(
        element,
        curveFrames(fade.curve, (opacity) => ({ opacity })),
        (fade.end - fade.begin) * transitionMs,
        fade.begin * transitionMs,
      ),
    ];
    void settled(entering[0]!).then((ended) => {
      if (!ended) return;
      for (const animation of entering) animation.cancel();
      entering = [];
      timer = setTimeout(hide, props.bar.durationMs);
    });
    return () => clearTimeout(timer);
  });

  /**
   * ScaffoldMessenger.hideCurrentSnackBar: the controller reverses from where it is. The M3 height's reverse curve is
   * Threshold(0), so the bar keeps its height and only fades, along the fade curve played backwards.
   */
  function hide() {
    if (hiding) return;
    hiding = true;
    clearTimeout(timer);
    element.style.pointerEvents = "none";
    const value = entering[0]?.effect?.getComputedTiming().progress ?? 1;
    for (const animation of entering) animation.cancel();
    const out = play(
      element,
      curveFrames((time) => fade.curve(1 - time), (opacity) => ({ opacity })),
      (fade.end - fade.begin) * transitionMs,
      (1 - fade.end) * transitionMs,
    );
    out.currentTime = (1 - value) * transitionMs * motionScale();
    const bar = props.bar;
    void settled(out).then(() => remove(bar));
  }

  function onPointerDown(event: PointerEvent) {
    if (event.pointerType === "mouse" || hiding || drag) return;
    drag = {
      pointer: event.pointerId,
      startY: event.clientY,
      size: 0,
      gap: 0,
      extent: 0,
      samples: [{ time: event.timeStamp, x: event.clientX, y: event.clientY }],
    };
  }

  function onPointerMove(event: PointerEvent) {
    if (!drag || event.pointerId !== drag.pointer) return;
    drag.samples.push({ time: event.timeStamp, x: event.clientX, y: event.clientY });
    while (drag.samples.length > 2 && event.timeStamp - drag.samples[0]!.time > 100) drag.samples.shift();
    if (drag.baseY === undefined) {
      if (Math.abs(event.clientY - drag.startY) < touchSlop) return;
      // A touch's events stay with the bar it began on (implicit pointer capture) as it moves out from under it.
      drag.baseY = event.clientY;
      // A drag while it comes in lets it be in at once.
      for (const animation of entering) animation.finish();
      const rect = element.getBoundingClientRect();
      const safeBottom = window.innerHeight - Math.max(insets().bottom, insets().keyboard);
      drag.gap = safeBottom - rect.bottom;
      drag.size = rect.height + drag.gap;
    }
    // Direction down: it follows the finger down, never up past where it rests.
    drag.extent = Math.min(drag.size, Math.max(0, event.clientY - drag.baseY));
    Object.assign(element.style, slid(drag.extent, drag.gap));
  }

  function onPointerUp(event: PointerEvent) {
    const done = drag;
    if (!done || event.pointerId !== done.pointer) return;
    drag = undefined;
    if (done.baseY === undefined) return;
    const first = done.samples[0]!;
    const seconds = Math.max(event.timeStamp - first.time, 1) / 1000;
    const velocityX = (event.clientX - first.x) / seconds;
    const velocityY = (event.clientY - first.y) / seconds;
    const fling =
      done.extent > 0 &&
      Math.abs(velocityY) >= minFlingVelocity &&
      Math.abs(velocityY) - Math.abs(velocityX) >= minFlingVelocityDelta;
    const value = done.extent / done.size;
    const away = event.type === "pointerup" && (fling ? velocityY > 0 : value > dismissThreshold);
    const target = away ? done.size : 0;
    // The controller runs the rest of its 200 ms, linearly; a fling at least as fast as the finger went.
    let ms = moveMs * Math.abs((target - done.extent) / done.size);
    if (fling) ms = Math.min(ms, (Math.abs(target - done.extent) / Math.abs(velocityY)) * 1000);
    const move = play(
      element,
      curveFrames(Curves.linear, (progress) => slid(done.extent + (target - done.extent) * progress, done.gap)),
      ms,
    );
    element.style.translate = "";
    element.style.clipPath = "";
    const bar = props.bar;
    void settled(move).then((ended) => {
      if (!ended) return;
      // Swiped away, ScaffoldMessenger.removeCurrentSnackBar: gone without fading; else back where it rests.
      if (away) {
        clearTimeout(timer);
        remove(bar);
      } else {
        move.cancel();
      }
    });
  }

  return (
    <div
      class={["snackbar", { "snackbar-error": props.bar.error }]}
      role="status"
      style={{ bottom }}
      ref={element}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={onPointerUp}
      onPointerCancel={onPointerUp}
    >
      <span class="snackbar-text">{props.bar.text}</span>
      <Show when={props.bar.action}>
        {(action) => (
          <button
            type="button"
            class="snackbar-action"
            data-ripple
            onClick={() => {
              hide();
              action().onPressed();
            }}
          >
            {action().label}
          </button>
        )}
      </Show>
    </div>
  );
}
