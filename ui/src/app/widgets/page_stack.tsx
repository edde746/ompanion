// Flutter's page routes for a stack of pages: the phone layout's pages (screens/shell/shell_screen.tsx) and the pages
// pushed over the app (navigator.tsx). A change of the top page plays the transition Flutter's default
// PageTransitionsTheme gives the platform (material/page_transitions_theme.dart, `_defaultBuilders`), as transform and
// opacity animations the compositor runs, so a page that mounts heavy content does not hold them up. A push, or a
// replace (Flutter's Navigator with pages pushes the new top over the old one and drops the old one after), brings the
// new page in over the old top; a pop takes the top away over the page under it. A page that leaves stays until its
// transition ends; pages under the top stay mounted and laid out, hidden, so their scroll positions survive. One
// transition at a time: a change while one runs ends it first. On iOS the top page follows a back swipe from the left
// edge, as cupertino/route.dart's _CupertinoBackGestureDetector does; on Android it follows the predictive back
// gesture, as material/predictive_back_page_transitions_builder.dart's _PredictiveBackSharedElementPageTransition does.
import type { JSX } from "@solidjs/web";
import { createEffect, createMemo, createSignal, flush, For, untrack } from "solid-js";
import { type Curve, Curves, cubic, curveFrames, flipped, interval, play, settled } from "../motion";
import { type BackEdge, type BackGesture, insets, isIOS, platform } from "../platform";
import { refreshDragRegions } from "../window_chrome";
import { horizontalDrag } from "./horizontal_drag";
import "./page_stack.css";

/** The builder Flutter's default PageTransitionsTheme has for the platform. */
type Kind = "cupertino" | "fadeForwards" | "zoom";

function kindOf(): Kind {
  switch (platform()) {
    case "ios":
    case "macos":
      return "cupertino";
    // PredictiveBackPageTransitionsBuilder, which is FadeForwardsPageTransitionsBuilder outside a predictive back
    // gesture.
    case "android":
      return "fadeForwards";
    case "windows":
    case "linux":
      return "zoom";
  }
}

/**
 * The builders' transitionDuration, which a pop takes too: CupertinoRouteTransitionMixin.kTransitionDuration,
 * FadeForwardsPageTransitionsBuilder.kTransitionMilliseconds, PageTransitionsBuilder's default for the zoom.
 */
const durationMs: Record<Kind, number> = { cupertino: 500, fadeForwards: 450, zoom: 300 };

/** _kDroppedSwipePageAnimationDuration: how long a released back swipe takes to finish, either way. */
const droppedSwipeMs = 350;

/** _CupertinoBackGestureDetector's strip along the left edge (_kBackGestureWidth), wider by a larger left inset. */
const backGestureWidth = 20;

/** How the route's animation moves: pushed (0 → 1), popped (1 → 0), or with a back swipe, which drives it linearly. */
type Direction = "push" | "pop" | "swipe";

/** The styles at a value of the route's animation: the top page's, the page's below, the edge shadow's, the scrim's. */
interface Frame {
  readonly top: Keyframe;
  readonly below: Keyframe;
  readonly shadow?: Keyframe;
  readonly scrim?: Keyframe;
}

const fastEaseFlipped = flipped(Curves.fastEaseInToSlowEaseOut);

/**
 * CupertinoPageTransition: the page slides in from the right edge, the page under it slides a third of the way left,
 * and the page's left edge casts _CupertinoEdgeShadowDecoration. A pop plays the reverse curves; a swipe none.
 */
function cupertinoFrame(direction: Direction, value: number): Frame {
  const position =
    direction === "push" ? Curves.fastEaseInToSlowEaseOut(value) : direction === "pop" ? fastEaseFlipped(value) : value;
  const parallax =
    direction === "push" ? Curves.linearToEaseOut(value) : direction === "pop" ? Curves.easeInToLinear(value) : value;
  const top = `translateX(${(1 - position) * 100}%)`;
  return {
    top: { transform: top },
    below: { transform: `translateX(${(-parallax * 100) / 3}%)` },
    // The shadow's curve has no reverse curve.
    shadow: { transform: top, opacity: direction === "swipe" ? value : Curves.linearToEaseOut(value) },
  };
}

const fadeIn = interval(0, 0.75);
const fadeOut = interval(0, 0.25);

/**
 * _FadeForwardsPageTransition: the page slides in from a quarter of the width while it fades in, the page under it
 * slides a quarter left while it fades out, over the surface colour (the body's). DualTransitionBuilder plays a pop
 * with the exit tweens over the reversed animation rather than the entry ones backwards.
 */
function fadeForwardsFrame(direction: Direction, value: number): Frame {
  const curve = Curves.easeInOutCubicEmphasized;
  if (direction === "pop") {
    const out = 1 - value;
    return {
      top: { transform: `translateX(${25 * curve(out)}%)`, opacity: 1 - fadeOut(out) },
      below: { transform: `translateX(${-25 * (1 - curve(out))}%)`, opacity: fadeIn(out) },
    };
  }
  return {
    top: { transform: `translateX(${25 * (1 - curve(value))}%)`, opacity: fadeIn(value) },
    below: { transform: `translateX(${-25 * curve(value)}%)`, opacity: 1 - fadeOut(value) },
  };
}

// _ZoomPageTransition._scaleCurveSequence: two tweens that come close to Android's fastOutExtraSlowIn.
const zoomFirst = cubic(0.05, 0, 0.133333, 0.06);
const zoomSecond = cubic(0.208333, 0.82, 0.25, 1);
const zoomScale: Curve = (t) =>
  t < 0.166666 ? 0.4 * zoomFirst(t / 0.166666) : 0.4 + 0.6 * zoomSecond((t - 0.166666) / (1 - 0.166666));
const zoomFadeIn = interval(0.125, 0.25);
const zoomFadeOut = interval(0.0825, 0.2075);
const zoomScrim = interval(0.2075, 0.4175);

/**
 * _ZoomEnterTransition and _ZoomExitTransition: a pushed page grows from 85 % as it fades in over a scrim of the
 * surface colour up to 60 %, the page under it grows to 105 %; a popped page shrinks to 90 % as it fades out, the page
 * under it shrinks from 110 %.
 */
function zoomFrame(direction: Direction, value: number): Frame {
  if (direction === "pop") {
    const out = 1 - value;
    return {
      top: { transform: `scale(${1 - 0.1 * zoomScale(out)})`, opacity: 1 - zoomFadeOut(out) },
      below: { transform: `scale(${1.1 - 0.1 * zoomScale(out)})` },
    };
  }
  return {
    top: { transform: `scale(${0.85 + 0.15 * zoomScale(value)})`, opacity: zoomFadeIn(value) },
    below: { transform: `scale(${1 + 0.05 * zoomScale(value)})` },
    scrim: { opacity: 0.6 * zoomScrim(value) },
  };
}

function frameAt(kind: Kind, direction: Direction, value: number): Frame {
  switch (kind) {
    case "cupertino":
      return cupertinoFrame(direction, value);
    case "fadeForwards":
      return fadeForwardsFrame(direction, value);
    case "zoom":
      return zoomFrame(direction, value);
  }
}

// _PredictiveBackSharedElementPageTransitionState's constants, from Android's predictive back motion specs.
const predictiveMinScale = 0.9;
const predictiveDivisionFactor = 20;
const predictiveMargin = 8;
const predictiveYPositionFactor = 0.1;
/** _kDeviceBorderRadius: the corner radius where the page cannot read the display's own corner radii. */
const predictiveCornerRadius = 32;
/** The route's transitionDuration, which a commit and a cancel run on: FadeForwardsPageTransitionsBuilder's. */
const predictiveMs = durationMs.fadeForwards;
/** _kCommitInterval: the commit's motion ends after _kCommitMilliseconds (400) of the route's 450. */
const predictiveCommit = interval(0, 400 / predictiveMs, Curves.easeInOutCubicEmphasized);

/** Android's predictive back gesture on the top page: the edge it began at and how far it is (0 to 1). */
interface Predictive {
  readonly top: HTMLElement;
  readonly below: HTMLElement | undefined;
  readonly edge: BackEdge;
  progress: number;
}

/**
 * The top page shrunk toward 90 % with its corners rounded toward 32 px by `bounce`, shifted `x` px, at `opacity`. Its
 * vertical shift follows the finger's vertical travel in Flutter, which the shell's events do not carry.
 */
function predictivePose(bounce: number, x: number, opacity: number): Keyframe {
  return {
    transform: `scale(${1 - (1 - predictiveMinScale) * bounce}) translateX(${x}px)`,
    opacity,
    clipPath: `inset(0 round ${predictiveCornerRadius * bounce}px)`,
  };
}

/** Where the gesture holds the top page at `progress`: shifted away from the edge it began at by up to a 20th of the width. */
function predictiveShift(edge: BackEdge, progress: number): number {
  const shift = window.innerWidth / predictiveDivisionFactor - predictiveMargin;
  return (edge === "left" ? shift : -shift) * progress;
}

/**
 * The commit at `t` of the route's reverse animation: the page grows back from where the gesture left it, slides to a
 * tenth of the screen's height (Flutter's own x offset) and fades out, all within the commit interval.
 */
function predictiveCommitFrame(gesture: Predictive, t: number): Frame {
  const from = predictiveShift(gesture.edge, gesture.progress);
  const moved = predictiveCommit(t);
  const to = window.innerHeight * predictiveYPositionFactor;
  return {
    top: predictivePose(gesture.progress * predictiveCommit(1 - t), from + (to - from) * moved, 1 - moved),
    below: {},
  };
}

/** Holds `element` in `keyframe`'s transform, opacity and clip; an empty one lets it rest. */
function pose(element: HTMLElement, keyframe: Keyframe): void {
  element.style.transform = keyframe.transform === undefined ? "" : String(keyframe.transform);
  element.style.opacity = keyframe.opacity === undefined ? "" : String(keyframe.opacity);
  element.style.clipPath = keyframe.clipPath === undefined ? "" : String(keyframe.clipPath);
}

/**
 * Shows or hides a page, and lets it take input or not. A page that takes none is hidden from ARIA too: inert alone does
 * not hide it from what reads only ARIA, such as the shot runner's role locators while two pages show in a transition.
 */
function place(element: HTMLElement | undefined, visible: boolean, active: boolean): void {
  if (!element) return;
  element.style.visibility = visible ? "" : "hidden";
  element.inert = !active;
  if (active) element.removeAttribute("aria-hidden");
  else element.setAttribute("aria-hidden", "true");
}

export interface PageStackProps<T extends object> {
  /** The pages, bottom first; a page is the same object for as long as it is on the stack. */
  readonly pages: readonly T[];
  readonly render: (page: T) => JSX.Element;
  /** The class of the stack's box, which the pages fill. */
  readonly class: string;
  readonly pageClass: (page: T) => string;
  /** A getter for what lies under the first page and moves as the page below it: the app under the pushed pages. */
  readonly base?: () => HTMLElement | undefined;
  /** Pops the top page at the end of a back swipe; the stack follows with its next `pages`. */
  readonly onSwipeBack: () => void;
  /**
   * Receives what makes the top page follow Android's predictive back gesture, for the back handler (`onBack`) that
   * pops it.
   */
  readonly gesture?: (gesture: BackGesture) => void;
}

interface Shown<T> {
  readonly pages: readonly T[];
  /** The old top while its transition runs: popped (it shows over the new top) or replaced (under it). */
  readonly leaving?: { readonly page: T; readonly popped: boolean };
}

/** A running transition: its animations, and what puts the pages at rest, at its end or when a change ends it early. */
interface Run {
  readonly animations: readonly Animation[];
  readonly end: () => void;
}

/** A back swipe under the finger: the pages it moves and the route animation's value it holds them at. */
interface Swipe {
  readonly top: HTMLElement;
  readonly below: HTMLElement | undefined;
  value: number;
}

export function PageStack<T extends object>(props: PageStackProps<T>) {
  const elements = new WeakMap<T, HTMLElement>();
  let shadow!: HTMLDivElement;
  let scrim!: HTMLDivElement;
  let running: Run | undefined;
  let swipe: Swipe | undefined;
  /** The value a released back swipe pops from, until the stack follows its pop. */
  let released: number | undefined;
  let predictive: Predictive | undefined;
  // A leaving page whose transition ended. Not compared: the phone layout's panels page may leave again later.
  const [gone, setGone] = createSignal<T | undefined>(undefined, { equals: false });

  const shown = createMemo<Shown<T>>((previous) => {
    const pages = props.pages;
    const ended = gone();
    if (previous === undefined) return { pages };
    if (pages === previous.pages) return previous.leaving?.page === ended ? { pages } : previous;
    const oldTop = previous.pages.at(-1);
    const newTop = pages.at(-1);
    if (oldTop === undefined || oldTop === newTop || pages.includes(oldTop)) return { pages };
    return { pages, leaving: { page: oldTop, popped: newTop === undefined || previous.pages.includes(newTop) } };
  });

  const rendered = createMemo(() => {
    const { pages, leaving } = shown();
    if (!leaving) return pages;
    return leaving.popped ? [...pages, leaving.page] : [...pages.slice(0, -1), leaving.page, ...pages.slice(-1)];
  });

  /** The element of `page`; with no page, the base. */
  function elementOf(page: T | undefined): HTMLElement | undefined {
    return page === undefined ? props.base?.() : elements.get(page);
  }

  /** What lies under the top page: the page below it, or the base under the first. */
  function belowTop(): HTMLElement | undefined {
    const pages = shown().pages;
    if (pages.length === 0) return undefined;
    const below = pages.at(-2);
    return below === undefined ? props.base?.() : elements.get(below);
  }

  /** Puts the pages at rest: the top one shown, the others hidden, and the base hidden under any page. */
  function rest(): void {
    const top = shown().pages.at(-1);
    for (const page of rendered()) place(elements.get(page), page === top, page === top);
    place(props.base?.(), top === undefined, top === undefined);
    refreshDragRegions();
  }

  /** Ends the running transition, or lets go of a swipe or a predictive back gesture, leaving the pages where it would. */
  function finish(): void {
    if (swipe) {
      pose(swipe.top, {});
      if (swipe.below) pose(swipe.below, {});
      pose(shadow, {});
      swipe = undefined;
    }
    if (predictive) {
      pose(predictive.top, {});
      predictive = undefined;
    }
    const current = running;
    running = undefined;
    current?.end();
  }

  /**
   * Plays `frame` (the styles at a fraction of the time) over `ms` on `top`, the page under it and the transition's
   * shadow or scrim; `end` puts the pages at rest once it finished, or when another change ends it first.
   */
  function run(
    top: HTMLElement,
    below: HTMLElement | undefined,
    frame: (t: number) => Frame,
    ms: number,
    end: () => void,
  ): void {
    const frames = (part: keyof Frame) => curveFrames(Curves.linear, (t) => frame(t)[part] ?? {});
    const first = frame(0);
    const topAnimation = play(top, frames("top"), ms);
    const animations = [topAnimation];
    if (below) animations.push(play(below, frames("below"), ms));
    if (first.shadow) animations.push(play(shadow, frames("shadow"), ms));
    if (first.scrim) {
      // The scrim follows the pages in the stack's box; the entering page goes over it.
      top.style.zIndex = "1";
      animations.push(play(scrim, frames("scrim"), ms));
    }
    // A gesture held the pages in place; the animations hold them now.
    pose(top, {});
    if (below) pose(below, {});
    pose(shadow, {});
    const current: Run = {
      animations,
      end: () => {
        for (const animation of animations) animation.cancel();
        top.style.zIndex = "";
        end();
      },
    };
    running = current;
    void settled(topAnimation).then((finished) => {
      if (!finished || running !== current) return;
      running = undefined;
      current.end();
    });
  }

  createEffect(shown, (now, before) => {
    // A leaving page went away at the end of its transition.
    if (before !== undefined && now.pages === before.pages) return;
    const gesture = predictive;
    finish();
    rest();
    const top = now.pages.at(-1);
    const oldTop = before?.pages.at(-1);
    if (before === undefined || top === oldTop) return;
    const leaving = now.leaving;
    const kind = kindOf();
    if (top !== undefined && !before.pages.includes(top)) {
      const entering = elements.get(top);
      if (!entering) return;
      // Pushed, or replacing the old top, which stays under the new page to the end.
      const below = elementOf(oldTop);
      place(below, true, false);
      run(entering, below, (t) => frameAt(kind, "push", t), durationMs[kind], () => {
        rest();
        if (leaving) setGone(() => leaving.page);
      });
      return;
    }
    if (!leaving?.popped) return;
    const element = elements.get(leaving.page);
    if (!element) return;
    place(element, true, false);
    const from = released;
    released = undefined;
    const below = elementOf(top);
    const end = () => {
      rest();
      setGone(() => leaving.page);
    };
    if (gesture?.top === element) {
      // The predictive back gesture committed: the page goes on from where the gesture left it.
      run(element, below, (t) => predictiveCommitFrame(gesture, t), predictiveMs, end);
    } else if (from !== undefined) {
      // A released back swipe pops on from where the finger left the page, as _CupertinoBackGestureController does.
      const value = (t: number) => from * (1 - Curves.fastEaseInToSlowEaseOut(t));
      run(element, below, (t) => frameAt(kind, "swipe", value(t)), droppedSwipeMs, end);
    } else {
      run(element, below, (t) => frameAt(kind, "pop", 1 - t), durationMs[kind], end);
    }
  });

  /** _CupertinoBackGestureController.dragUpdate: the finger moved `delta` px. */
  function moveSwipe(delta: number): void {
    if (!swipe) return;
    swipe.value = Math.min(1, Math.max(0, swipe.value - delta / swipe.top.clientWidth));
    const frame = cupertinoFrame("swipe", swipe.value);
    pose(swipe.top, frame.top);
    if (swipe.below) pose(swipe.below, frame.below);
    pose(shadow, frame.shadow ?? {});
  }

  /**
   * _CupertinoBackGestureController.dragEnd: a fling of a screen width per second (_kMinFlingVelocity) goes its way,
   * a slower release the way the page is closer to; either finishes linearly along fastEaseInToSlowEaseOut.
   */
  function releaseSwipe(velocity: number): void {
    if (!swipe) return;
    const { top, below, value } = swipe;
    swipe = undefined;
    const screens = velocity / top.clientWidth;
    if (Math.abs(screens) >= 1 ? screens > 0 : value <= 0.5) {
      released = value;
      props.onSwipeBack();
      // The stack's effect takes `released` up as it plays the pop.
      flush();
      if (released === undefined) return;
      released = undefined;
    }
    const at = (t: number) => value + (1 - value) * Curves.fastEaseInToSlowEaseOut(t);
    run(top, below, (t) => cupertinoFrame("swipe", at(t)), droppedSwipeMs, rest);
  }

  /** The iOS back swipe on `element`, the page of `page`, while it is the top one and a page or the base lies under it. */
  function swipeBack(element: HTMLElement, page: T): void {
    horizontalDrag(element, {
      accepts: (touch) =>
        running === undefined &&
        swipe === undefined &&
        shown().pages.at(-1) === page &&
        belowTop() !== undefined &&
        touch.clientX - element.getBoundingClientRect().left < Math.max(insets().left, backGestureWidth),
      onStart: () => {
        const below = belowTop();
        place(below, true, false);
        swipe = { top: element, below, value: 1 };
      },
      onUpdate: moveSwipe,
      onEnd: releaseSwipe,
    });
  }

  const gesture: BackGesture = {
    start: (edge) => {
      const page = shown().pages.at(-1);
      const top = page === undefined ? undefined : elements.get(page);
      const below = belowTop();
      // A route takes the gesture only once its own transition is over.
      if (running !== undefined || swipe !== undefined || top === undefined || below === undefined) return;
      place(below, true, false);
      predictive = { top, below, edge, progress: 0 };
    },
    progress: (value) => {
      if (!predictive) return;
      predictive.progress = value;
      pose(predictive.top, predictivePose(value, predictiveShift(predictive.edge, value), 1));
    },
    // The route's animation runs forward again, over the part of its duration the gesture took back.
    cancel: () => {
      const held = predictive;
      if (!held) return;
      predictive = undefined;
      const { edge, progress } = held;
      const at = (t: number) => progress * (1 - t);
      const frame = (t: number): Frame => ({ top: predictivePose(at(t), predictiveShift(edge, at(t)), 1), below: {} });
      run(held.top, held.below, frame, predictiveMs * progress, rest);
    },
  };
  untrack(() => props.gesture)?.(gesture);

  return (
    <div class={props.class}>
      <For each={rendered()}>
        {(page) => (
          <div
            class={props.pageClass(page)}
            ref={(element) => {
              elements.set(page, element);
              if (isIOS()) swipeBack(element, page);
            }}
          >
            {props.render(page)}
          </div>
        )}
      </For>
      <div class="page-stack-shadow" ref={shadow} />
      <div class="page-stack-scrim" ref={scrim} />
    </div>
  );
}
