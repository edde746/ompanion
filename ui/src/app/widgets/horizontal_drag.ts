// Flutter's HorizontalDragGestureRecognizer for touches (gestures/monodrag.dart, velocity_tracker.dart): a drag begins
// once the finger travels kTouchSlop sideways before it travels that far up or down (a scrollable's vertical drag would
// win then), and ends with the release's velocity when that was a fling. Touch events rather than pointer events: the
// browser cancels a pointer once it starts a pan of its own, and only a non-passive touchmove keeps the page from
// scrolling while the drag is undecided and once it began.

const touchSlop = 18; // kTouchSlop
const minFlingVelocity = 50; // kMinFlingVelocity, px/s
const maxFlingVelocity = 8000; // kMaxFlingVelocity, px/s
// VelocityTracker: it looks at the last 100 ms of moves (_horizonMilliseconds) and takes a finger that rested 40 ms
// before lifting as stopped (_assumePointerMoveStoppedMilliseconds).
const horizonMs = 100;
const stoppedMs = 40;

export interface HorizontalDragHandlers {
  /** Whether a touch that went down at `touch` may become a drag. */
  readonly accepts: (touch: Touch) => boolean;
  readonly onStart: () => void;
  /** The finger moved `delta` px sideways since the last update (DragUpdateDetails.primaryDelta). */
  readonly onUpdate: (delta: number) => void;
  /** The finger lifted, flinging at `velocity` px/s (0 when the release was no fling), or the touch was cancelled. */
  readonly onEnd: (velocity: number) => void;
}

interface Sample {
  readonly ms: number;
  readonly x: number;
}

interface Tracked {
  readonly id: number;
  readonly startX: number;
  readonly startY: number;
  dragging: boolean;
  x: number;
  samples: Sample[];
}

/** Recognizes horizontal drags of the touches that go down on `element`, for as long as it lives. */
export function horizontalDrag(element: HTMLElement, handlers: HorizontalDragHandlers): void {
  let tracked: Tracked | undefined;

  const start = (event: TouchEvent) => {
    const touch = event.changedTouches[0];
    if (tracked || event.touches.length !== 1 || !touch || !handlers.accepts(touch)) return;
    tracked = { id: touch.identifier, startX: touch.clientX, startY: touch.clientY, dragging: false, x: 0, samples: [] };
  };

  const move = (event: TouchEvent) => {
    const touch = Array.from(event.changedTouches).find((each) => each.identifier === tracked?.id);
    if (!tracked || !touch) return;
    if (!tracked.dragging) {
      // An uncancelable move: the page began a scroll of its own, which wins.
      if (!event.cancelable) {
        tracked = undefined;
        return;
      }
      const dx = Math.abs(touch.clientX - tracked.startX);
      const dy = Math.abs(touch.clientY - tracked.startY);
      if (dy > touchSlop && dy > dx) {
        tracked = undefined;
        return;
      }
      if (dx < dy) return;
      event.preventDefault();
      if (dx <= touchSlop) return;
      // DragStartBehavior.start: the drag starts where it was recognized, without the slop's jump.
      tracked.dragging = true;
      tracked.x = touch.clientX;
      tracked.samples = [{ ms: event.timeStamp, x: touch.clientX }];
      handlers.onStart();
      return;
    }
    event.preventDefault();
    const delta = touch.clientX - tracked.x;
    tracked.x = touch.clientX;
    tracked.samples.push({ ms: event.timeStamp, x: touch.clientX });
    handlers.onUpdate(delta);
  };

  const end = (event: TouchEvent) => {
    const touch = Array.from(event.changedTouches).find((each) => each.identifier === tracked?.id);
    if (!tracked || !touch) return;
    const ended = tracked;
    tracked = undefined;
    if (ended.dragging) handlers.onEnd(event.type === "touchend" ? flingVelocity(ended.samples, event.timeStamp) : 0);
  };

  element.addEventListener("touchstart", start, { passive: true });
  element.addEventListener("touchmove", move, { passive: false });
  element.addEventListener("touchend", end, { passive: true });
  element.addEventListener("touchcancel", end, { passive: true });
}

/** DragGestureRecognizer's end velocity: the last moves' speed when it makes a fling (isFlingGesture), else 0. */
function flingVelocity(samples: readonly Sample[], endMs: number): number {
  const last = samples.at(-1);
  if (!last || endMs - last.ms > stoppedMs) return 0;
  const first = samples.find((sample) => last.ms - sample.ms <= horizonMs);
  if (!first || first === last) return 0;
  const offset = last.x - first.x;
  const velocity = (offset / (last.ms - first.ms)) * 1000;
  if (Math.abs(velocity) <= minFlingVelocity || Math.abs(offset) <= touchSlop) return 0;
  return Math.max(-maxFlingVelocity, Math.min(maxFlingVelocity, velocity));
}
