// Flutter's InkRipple (material/ink_ripple.dart, the theme's splashFactory) with InkWell's pressed highlight
// (material/ink_well.dart) for every element marked `data-ripple`. Document listeners follow the primary pointer as
// InkWell's tap recognizer does: the press shows from tap-down (at once for a mouse; for touch after kPressTimeout or at
// the release, so a scroll claims the pointer first), fades away when the pointer travels past kTouchSlop or the browser
// takes it for a scroll, and a release (or a long press the element acts on) sends the ripple across the element.
// Keyboard activation draws none; the element's focus layer shows instead. Both layers take the element's currentColor.
import { Curves, curveFrames, play, settled } from "../motion";
import "./ripple.css";

/** gestures/constants.dart. */
const pressTimeoutMs = 100;
const touchSlop = 18;
/** ink_ripple.dart: the radius runs over 1 s until the press is confirmed, then finishes over 225 ms. */
const unconfirmedMs = 1000;
const radiusMs = 225;
const fadeInMs = 75;
const fadeOutMs = 375;
const cancelMs = 75;
/** _kFadeOutIntervalStart: the confirmed ripple stays at full strength through the radius's 225 ms. */
const fadeOutStart = 225 / 375;
/** ink_well.dart getFadeDurationForType(pressed). */
const highlightMs = 200;
/** Material 3's pressed state layer, for the highlight and the splash alike. */
const pressedOpacity = 0.1;

interface Ink {
  readonly layer: HTMLElement;
  readonly highlight: HTMLElement;
  readonly splash: HTMLElement;
  readonly grow: Animation;
  readonly highlightFade: Animation;
  readonly splashFade: Animation;
}

interface Press {
  readonly pointerId: number;
  readonly host: HTMLElement;
  readonly x: number;
  readonly y: number;
  timer?: ReturnType<typeof setTimeout>;
  ink?: Ink;
}

let press: Press | undefined;

function span(className: string): HTMLSpanElement {
  const element = document.createElement("span");
  element.className = className;
  return element;
}

/** The splash's and highlight's strength now, as a fraction of their full one. */
function shown(element: HTMLElement): number {
  return Number(getComputedStyle(element).opacity) / pressedOpacity;
}

function startInk(host: HTMLElement, x: number, y: number): Ink {
  const box = host.getBoundingClientRect();
  const layer = host.querySelector<HTMLElement>(":scope > .ink-ripple") ?? host.appendChild(span("ink-ripple"));
  const highlight = layer.appendChild(span("ink-ripple-highlight"));
  const splash = layer.appendChild(span("ink-ripple-splash"));
  // _getTargetRadius: half the box's diagonal. The circle grows from 30 % of it to 5 px past it while its centre moves
  // from the press to the box's centre, both along Curves.ease.
  const target = Math.hypot(box.width, box.height) / 2;
  const end = target + 5;
  splash.style.left = `${box.width / 2 - end}px`;
  splash.style.top = `${box.height / 2 - end}px`;
  splash.style.width = splash.style.height = `${2 * end}px`;
  const dx = x - box.left - box.width / 2;
  const dy = y - box.top - box.height / 2;
  const grow = play(
    splash,
    curveFrames(Curves.ease, (t) => ({
      transform: `translate(${dx * (1 - t)}px, ${dy * (1 - t)}px) scale(${(0.3 * target + (end - 0.3 * target) * t) / end})`,
    })),
    unconfirmedMs,
  );
  return {
    layer,
    highlight,
    splash,
    grow,
    highlightFade: play(highlight, [{ opacity: 0 }, { opacity: pressedOpacity }], highlightMs),
    splashFade: play(splash, [{ opacity: 0 }, { opacity: pressedOpacity }], fadeInMs),
  };
}

/** The splash's strength in InkRipple's fade-out at `value` of its controller. */
function fadeOutOpacity(value: number): number {
  return pressedOpacity * (1 - Math.max(0, (value - fadeOutStart) / (1 - fadeOutStart)));
}

function endInk(ink: Ink, confirmed: boolean): void {
  const highlight = shown(ink.highlight);
  ink.highlightFade.cancel();
  const highlightFade = play(ink.highlight, [{ opacity: highlight * pressedOpacity }, { opacity: 0 }], highlightMs * highlight);
  const splash = shown(ink.splash);
  ink.splashFade.cancel();
  let splashFade: Animation;
  if (confirmed) {
    ink.grow.playbackRate = unconfirmedMs / radiusMs;
    // The fade-in finishes first; the fade-out keeps full strength until _kFadeOutIntervalStart.
    splashFade = play(
      ink.splash,
      [
        { opacity: splash * pressedOpacity, offset: 0 },
        { opacity: pressedOpacity, offset: ((1 - splash) * fadeInMs) / fadeOutMs },
        { opacity: pressedOpacity, offset: fadeOutStart },
        { opacity: 0, offset: 1 },
      ],
      fadeOutMs,
    );
  } else {
    // cancel(): the fade-out starts at 1 − the fade-in's progress and runs out over what is left of _kCancelDuration.
    const from = 1 - splash;
    splashFade = play(
      ink.splash,
      [
        { opacity: fadeOutOpacity(from), offset: 0 },
        ...(from < fadeOutStart ? [{ opacity: pressedOpacity, offset: (fadeOutStart - from) / (1 - from) }] : []),
        { opacity: 0, offset: 1 },
      ],
      cancelMs * splash,
    );
  }
  void Promise.all([settled(highlightFade), settled(splashFade)]).then(() => {
    ink.highlight.remove();
    ink.splash.remove();
    if (!ink.layer.hasChildNodes()) ink.layer.remove();
  });
}

function finish(confirmed: boolean): void {
  const current = press;
  if (!current) return;
  press = undefined;
  clearTimeout(current.timer);
  // A tap released before kPressTimeout: tap-down and tap arrive together.
  if (!current.ink && confirmed) current.ink = startInk(current.host, current.x, current.y);
  if (current.ink) endInk(current.ink, confirmed);
}

/** InkWell's handleLongPress: an element that acts on a long press confirms its ripple then, not at the release. */
export function confirmRipple(): void {
  finish(true);
}

const listen = { capture: true, passive: true };

/**
 * What can take a press. The innermost one gets it, as the deepest recognizer wins Flutter's gesture arena: a switch in
 * a row toggles without the row's ripple.
 */
const pressable =
  "[data-ripple], button, a[href], input, textarea, select, [contenteditable='true'], [role='button'], [role='switch'], [role='checkbox'], [role='radio'], [role='tab']";

document.addEventListener(
  "pointerdown",
  (event) => {
    if (!event.isPrimary || event.button !== 0 || !(event.target instanceof Element)) return;
    // A press whose release went unseen (outside the window) ends with the next one.
    finish(false);
    const host = event.target.closest<HTMLElement>(pressable);
    if (!host?.hasAttribute("data-ripple") || host.matches(":disabled, [aria-disabled='true']")) return;
    const current: Press = { pointerId: event.pointerId, host, x: event.clientX, y: event.clientY };
    press = current;
    if (event.pointerType === "mouse") current.ink = startInk(host, current.x, current.y);
    else current.timer = setTimeout(() => (current.ink = startInk(host, current.x, current.y)), pressTimeoutMs);
  },
  listen,
);

document.addEventListener(
  "pointermove",
  (event) => {
    if (press?.pointerId !== event.pointerId) return;
    if (Math.hypot(event.clientX - press.x, event.clientY - press.y) > touchSlop) finish(false);
  },
  listen,
);

document.addEventListener(
  "pointerup",
  (event) => {
    if (press?.pointerId === event.pointerId) finish(true);
  },
  listen,
);

// The browser took the pointer: a scroll, a pinch, a native drag.
document.addEventListener(
  "pointercancel",
  (event) => {
    if (press?.pointerId === event.pointerId) finish(false);
  },
  listen,
);

// Android's long press opens the context menu; an element that takes it (preventDefault) acted on the long press.
window.addEventListener("contextmenu", (event) => {
  if (event.defaultPrevented) finish(true);
});
