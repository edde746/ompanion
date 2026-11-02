// Flutter's motion for the page: its curves (animation/curves.dart) as functions of t in [0, 1], and keyframes sampled
// from them for `element.animate`, because CSS draws only plain cubic Béziers (`linear()` easing needs Safari 17.2)
// and Flutter's emphasized curves are two Béziers joined. Stylesheets use the Bézier ones from theme.css
// (`--curve-…`); motion driven from script (page transitions, menus, dialogs, gestures) goes through here.
import { deferred } from "../deferred";

export type Curve = (t: number) => number;

const linear: Curve = (t) => t;

/** Flutter's Cubic: a Bézier from (0, 0) to (1, 1) through control points (a, b) and (c, d), solved as Flutter does. */
export function cubic(a: number, b: number, c: number, d: number): Curve {
  const evaluate = (p: number, q: number, m: number) => 3 * p * (1 - m) * (1 - m) * m + 3 * q * (1 - m) * m * m + m * m * m;
  return (t) => {
    if (t <= 0 || t >= 1) return t <= 0 ? 0 : 1;
    let start = 0;
    let end = 1;
    for (;;) {
      const midpoint = (start + end) / 2;
      const estimate = evaluate(a, c, midpoint);
      if (Math.abs(t - estimate) < 0.001) return evaluate(b, d, midpoint);
      if (estimate < t) start = midpoint;
      else end = midpoint;
    }
  };
}

type Point = readonly [x: number, y: number];

/** Flutter's ThreePointCubic: two Béziers joined at `midpoint`. */
export function threePointCubic(a1: Point, b1: Point, midpoint: Point, a2: Point, b2: Point): Curve {
  const [mx, my] = midpoint;
  const first = cubic(a1[0] / mx, a1[1] / my, b1[0] / mx, b1[1] / my);
  const second = cubic(
    (a2[0] - mx) / (1 - mx),
    (a2[1] - my) / (1 - my),
    (b2[0] - mx) / (1 - mx),
    (b2[1] - my) / (1 - my),
  );
  return (t) => {
    if (t <= 0 || t >= 1) return t <= 0 ? 0 : 1;
    return t < mx ? first(t / mx) * my : second((t - mx) / (1 - mx)) * (1 - my) + my;
  };
}

/** Flutter's Interval: 0 until `begin`, `curve` across [begin, end], 1 after. */
export function interval(begin: number, end: number, curve: Curve = linear): Curve {
  return (t) => {
    const local = Math.min(1, Math.max(0, (t - begin) / (end - begin)));
    return local === 0 || local === 1 ? local : curve(local);
  };
}

/** Flutter's FlippedCurve: the curve played backwards and upside down, as reverse curves are. */
export function flipped(curve: Curve): Curve {
  return (t) => 1 - curve(1 - t);
}

/** Flutter's `Curves` and Material 3's `Easing`, the ones the app's motion uses. */
export const Curves = {
  linear,
  ease: cubic(0.25, 0.1, 0.25, 1),
  easeIn: cubic(0.42, 0, 1, 1),
  easeOut: cubic(0, 0, 0.58, 1),
  easeOutBack: cubic(0.175, 0.885, 0.32, 1.275),
  easeInOut: cubic(0.42, 0, 0.58, 1),
  easeInOutQuart: cubic(0.77, 0, 0.175, 1),
  easeInCirc: cubic(0.6, 0.04, 0.98, 0.335),
  fastOutSlowIn: cubic(0.4, 0, 0.2, 1),
  decelerate: ((t) => 1 - (1 - t) * (1 - t)) as Curve,
  linearToEaseOut: cubic(0.35, 0.91, 0.33, 0.97),
  easeInToLinear: cubic(0.67, 0.03, 0.65, 0.09),
  fastEaseInToSlowEaseOut: threePointCubic([0.056, 0.024], [0.108, 0.3085], [0.198, 0.541], [0.3655, 1], [0.5465, 0.989]),
  easeInOutCubicEmphasized: threePointCubic([0.05, 0], [0.133333, 0.06], [0.166666, 0.4], [0.208333, 0.82], [0.25, 1]),
  standard: cubic(0.2, 0, 0, 1),
  emphasizedDecelerate: cubic(0.05, 0.7, 0.1, 1),
  emphasizedAccelerate: cubic(0.3, 0, 0.8, 0.15),
} as const;

/**
 * What durations are multiplied by: 0.05 while the system asks for less motion, as Flutter's AnimationController does
 * under `disableAnimations`, so a change still reads as a change without travelling across the screen.
 */
export function motionScale(): number {
  return window.matchMedia("(prefers-reduced-motion: reduce)").matches ? 0.05 : 1;
}

/**
 * Keyframes that make a linear animation follow `curve`: `frame(value)` at `steps + 1` evenly spaced offsets, with
 * value = curve(offset) (a progress from 0 to 1 that `frame` maps to styles, e.g. a translation).
 */
export function curveFrames(curve: Curve, frame: (value: number) => Keyframe, steps = 24): Keyframe[] {
  const frames: Keyframe[] = [];
  for (let index = 0; index <= steps; index++) {
    const offset = index / steps;
    frames.push({ ...frame(curve(offset)), offset });
  }
  return frames;
}

/**
 * Plays `keyframes` on `element` over `durationMs` (scaled by motionScale()), linearly between them, holding the first
 * frame through `delayMs` and the last after the end. The held frame overrides the element's own style until the
 * caller cancels the animation: once the element rests in that state by itself, or is removed.
 */
export function play(element: Element, keyframes: Keyframe[], durationMs: number, delayMs = 0): Animation {
  const scale = motionScale();
  return element.animate(keyframes, { duration: durationMs * scale, delay: delayMs * scale, easing: "linear", fill: "both" });
}

/** Resolves with true once `animation` finishes, false when it is cancelled first. */
export function settled(animation: Animation): Promise<boolean> {
  if (animation.playState === "finished") return Promise.resolve(true);
  const done = deferred<boolean>();
  animation.addEventListener("finish", () => done.resolve(true), { once: true });
  animation.addEventListener("cancel", () => done.resolve(false), { once: true });
  return done.promise;
}
