// The medium layout's dock as an end drawer (lib's Scaffold `endDrawer: Drawer(width: 360, child: SafeArea(child:
// DockPanel()))`) with DrawerController's motion (material/drawer.dart): it slides in from the right edge over a scrim
// that darkens with it, both on AnimationController.fling's spring, and goes out the same way. On a touch screen a
// sideways drag moves the open drawer, and its release flings it open or shut. The drawer is built while it is not
// shut, as DrawerController builds its child only then.
import type { JSX } from "@solidjs/web";
import { createEffect, createSignal, Show } from "solid-js";
import { type Curve, curveFrames, play, settled } from "../../motion";
import { isTouch } from "../../platform";
import { horizontalDrag } from "../../widgets/horizontal_drag";
import "./dock_drawer.css";

/** _kMinFlingVelocity: a release this fast (px/s) flings the drawer its way. */
const minFlingVelocity = 365;

/**
 * AnimationController.fling: a critically damped spring (_kFlingSpringDescription: mass 1, stiffness 500) from `from`
 * at `velocity` (drawer widths per second) toward just past the bound it heads for, done within 0.01 of that target
 * (_kFlingTolerance); the controller holds its value within [0, 1]. Returns the value along the time and the time.
 */
function fling(from: number, velocity: number): { readonly value: Curve; readonly ms: number } {
  const target = velocity < 0 ? -0.01 : 1.01;
  // -damping / (2 × mass), the damping being 2 × √(stiffness × mass) at a damping ratio of 1.
  const rate = -Math.sqrt(500);
  const start = from - target;
  const slope = velocity - rate * start;
  const offset = (seconds: number) => (start + slope * seconds) * Math.exp(rate * seconds);
  let seconds = 0;
  while (Math.abs(offset(seconds)) >= 0.01) seconds += 0.001;
  return { value: (t) => Math.min(1, Math.max(0, target + offset(t * seconds))), ms: seconds * 1000 };
}

/** Whether a touch on `target` lands in content that scrolls sideways, whose own drag wins over the drawer's. */
function scrollsSideways(target: EventTarget | null, box: HTMLElement): boolean {
  let element = target instanceof Element ? target : null;
  for (; element && element !== box; element = element.parentElement) {
    if (element.scrollWidth > element.clientWidth && /auto|scroll/.test(getComputedStyle(element).overflowX)) return true;
  }
  return false;
}

export function DockDrawer(props: {
  readonly open: boolean;
  readonly width: number;
  /** The drawer was dismissed: the scrim tapped, or dragged shut. */
  readonly onClose: () => void;
  readonly children: JSX.Element;
}) {
  const [built, setBuilt] = createSignal(false);
  let drawer: HTMLDivElement | undefined;
  let scrim: HTMLDivElement | undefined;
  /** The controller's value: 0 shut, 1 open. */
  let value = 0;
  /** Where the running fling heads: 1 open, 0 shut. */
  let heading = 0;
  let motion: { readonly animations: readonly Animation[]; readonly value: Curve } | undefined;

  /** Holds the drawer and the scrim at `value`; with no value lets them rest open. */
  function pose(at: number | undefined) {
    if (!drawer || !scrim) return;
    drawer.style.transform = at === undefined ? "" : `translateX(${(1 - at) * 100}%)`;
    scrim.style.opacity = at === undefined ? "" : String(at);
  }

  /** AnimationController.stop: the value stays where the fling was. */
  function stop() {
    if (!motion) return;
    const progress = motion.animations[0]?.effect?.getComputedTiming().progress ?? 1;
    value = motion.value(progress);
    for (const animation of motion.animations) animation.cancel();
    motion = undefined;
    pose(value);
  }

  /** DrawerController's open() and close(): a fling at `velocity` widths per second, shut below 0. */
  function settle(velocity: number) {
    stop();
    if (!drawer || !scrim) return;
    heading = velocity < 0 ? 0 : 1;
    const spring = fling(value, velocity);
    const slide = play(
      drawer,
      curveFrames(spring.value, (at) => ({ transform: `translateX(${(1 - at) * 100}%)` })),
      spring.ms,
    );
    const animations = [slide, play(scrim, curveFrames(spring.value, (at) => ({ opacity: at })), spring.ms)];
    pose(undefined);
    const current = { animations, value: spring.value };
    motion = current;
    void settled(slide).then((finished) => {
      if (!finished || motion !== current) return;
      motion = undefined;
      value = heading;
      if (heading === 0) {
        setBuilt(false);
        return;
      }
      for (const animation of animations) animation.cancel();
    });
  }

  createEffect(
    () => props.open,
    (open) => {
      if (open && !built()) setBuilt(true);
      else if (open !== (heading === 1) && built()) settle(open ? 1 : -1);
    },
  );
  // Built shut: it opens.
  createEffect(built, (shown) => {
    if (!shown) return;
    value = 0;
    settle(1);
  });

  /** DrawerController's drag of the open drawer: _move follows the finger, _settle flings it on release. */
  function drag(box: HTMLDivElement) {
    if (!isTouch()) return;
    horizontalDrag(box, {
      accepts: (touch) => !scrollsSideways(touch.target, box),
      onStart: stop,
      onUpdate: (delta) => {
        if (motion || !drawer) return;
        // An end drawer: a drag toward the right edge shuts it.
        value = Math.min(1, Math.max(0, value - delta / drawer.offsetWidth));
        pose(value);
      },
      onEnd: (velocity) => {
        if (motion || !drawer) return;
        const fast = Math.abs(velocity) >= minFlingVelocity;
        const widths = fast ? -velocity / drawer.offsetWidth : value < 0.5 ? -1 : 1;
        settle(widths);
        if (widths < 0) props.onClose();
      },
    });
  }

  return (
    <Show when={built()}>
      <div class="dock-drawer-box" ref={drag}>
        <div class="dock-drawer-scrim" ref={scrim} onClick={() => props.onClose()} />
        <div class="dock-drawer" ref={drawer} style={{ width: `${props.width}px` }}>
          {props.children}
        </div>
      </div>
    </Show>
  );
}
