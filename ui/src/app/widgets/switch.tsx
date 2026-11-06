// Material 3's Switch through the theme: monochrome, no outline. Off: an onSurfaceVariant 16 px thumb on a
// surfaceContainerHighest track; on: an onPrimary 24 px thumb on primary. Its motion is material/switch.dart's for
// Material 3: a toggle carries the thumb along Curves.easeOutBack while it stretches to 34 × 22 and settles to the new
// size; a press grows it to 28 px (the radial reaction); a horizontal drag carries it, and the release settles it on the
// nearer side. The colours follow the toggle (switch.css); during a drag they stay until the release decides.
import { createEffect, createMemo } from "solid-js";
import { cubic, Curves, curveFrames, play, settled } from "../motion";
import "./switch.css";

export interface SwitchProps {
  readonly value: boolean;
  /** Absent: the switch is disabled. */
  readonly onChanged?: (value: boolean) => void;
  readonly label?: string;
}

interface Thumb {
  /** The centre's distance from the track's left edge. */
  readonly x: number;
  readonly width: number;
  readonly height: number;
}

/** _SwitchConfigM3.toggleDuration. */
const toggleMs = 300;
/** kRadialReactionDuration: the press reaction. */
const reactionMs = 100;
/** The thumb's centre off, and how far it travels: trackHeight / 2 in from either end of the 52 px track. */
const offX = 16;
const travel = 20;
/** _SwitchConfigM3's thumb sizes: off, on, pressed, and halfway through a toggle (transitionalThumbSize). */
const offSize = 16;
const onSize = 24;
const pressedSize = 28;
const transitional = { width: 34, height: 22 };
/** The first part of _SwitchPainter.thumbSizeAnimation. */
const stretch = cubic(0.31, 0, 0.56, 1);

function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

/**
 * The toggle, over the controller's linear progress s: the centre along Curves.easeOutBack; the size to the
 * transitional one over the first 11 %, then to the end size over the next 72 % (thumbSizeAnimation's weights).
 */
function toggleFrames(from: Thumb, on: boolean): Keyframe[] {
  const to = { x: on ? offX + travel : offX, width: on ? onSize : offSize, height: on ? onSize : offSize };
  return curveFrames(
    Curves.linear,
    (s) => {
      const [start, end, t] =
        s < 0.11
          ? [from, transitional, stretch(s / 0.11)]
          : s < 0.83
            ? [transitional, to, Curves.standard((s - 0.11) / 0.72)]
            : [to, to, 1];
      return {
        left: `${lerp(from.x, to.x, Curves.easeOutBack(s))}px`,
        width: `${lerp(start.width, end.width, t)}px`,
        height: `${lerp(start.height, end.height, t)}px`,
      };
    },
    30,
  );
}

/** The press reaction and its release: the thumb grows or shrinks where it stands, along Curves.fastOutSlowIn. */
function resizeFrames(from: Thumb, size: number): Keyframe[] {
  return curveFrames(Curves.fastOutSlowIn, (t) => ({
    width: `${lerp(from.width, size, t)}px`,
    height: `${lerp(from.height, size, t)}px`,
  }));
}

export function Switch(props: SwitchProps) {
  let track!: HTMLButtonElement;
  let thumb!: HTMLSpanElement;
  let motion: Animation | undefined;
  /** The side a toggle is carrying the thumb to, so the value's change does not restart it. */
  let heading: boolean | undefined;
  let drag: { readonly pointerId: number; readonly startX: number; readonly from: number; dragging: boolean } | undefined;
  /** A drag's release also clicks; the drag already decided. */
  let dragged = false;

  /** Moves the thumb from where it shows now; the stylesheet's resting state takes over at the end. */
  function move(frames: (from: Thumb) => Keyframe[], durationMs: number): void {
    const style = getComputedStyle(thumb);
    const from = { x: parseFloat(style.left), width: parseFloat(style.width), height: parseFloat(style.height) };
    motion?.cancel();
    thumb.style.removeProperty("left");
    const animation = play(thumb, frames(from), durationMs);
    motion = animation;
    void settled(animation).then((finished) => {
      if (!finished) return;
      animation.cancel();
      heading = undefined;
    });
  }

  function toggle(on: boolean): void {
    heading = on;
    move((from) => toggleFrames(from, on), toggleMs);
  }

  // An effect runs each time its compute does, equal value or not; a memo passes on only a change, so a switch whose
  // value is read from shared state does not toggle again when something else in it changes.
  const value = createMemo(() => props.value);
  createEffect(
    value,
    (on) => {
      if (heading !== on) toggle(on);
    },
    { defer: true },
  );

  function release(event: PointerEvent): void {
    if (drag?.pointerId !== event.pointerId) return;
    const { dragging } = drag;
    drag = undefined;
    delete track.dataset.pressed;
    if (!dragging) {
      // A tap: its click toggles from the pressed size; a cancelled press shrinks back. A toggle under way goes on.
      if (heading === undefined) move((from) => resizeFrames(from, props.value ? onSize : offSize), reactionMs);
      return;
    }
    if (event.type === "pointercancel") {
      // The system took the pointer (a scroll, a system gesture): the thumb goes back and the value stays.
      toggle(props.value);
      return;
    }
    dragged = true;
    // _handleDragEnd: the nearer side wins.
    const on = (parseFloat(getComputedStyle(thumb).left) - offX) / travel >= 0.5;
    toggle(on);
    if (on !== props.value) props.onChanged?.(on);
  }

  return (
    <button
      type="button"
      role="switch"
      aria-checked={props.value ? "true" : "false"}
      aria-label={props.label}
      class={["switch", { "switch-on": props.value }]}
      disabled={!props.onChanged}
      ref={track}
      onClick={() => {
        if (dragged) {
          dragged = false;
          return;
        }
        props.onChanged?.(!props.value);
      }}
      onPointerDown={(event) => {
        if (!props.onChanged || !event.isPrimary || event.button !== 0) return;
        // A touch drag's release clicks nothing, so the flag would outlive it.
        dragged = false;
        const position = (parseFloat(getComputedStyle(thumb).left) - offX) / travel;
        drag = { pointerId: event.pointerId, startX: event.clientX, from: position, dragging: false };
        track.dataset.pressed = "";
        if (heading === undefined) move((from) => resizeFrames(from, pressedSize), reactionMs);
      }}
      onPointerMove={(event) => {
        if (drag?.pointerId !== event.pointerId) return;
        const dx = event.clientX - drag.startX;
        if (!drag.dragging) {
          // Where a horizontal drag starts: kTouchSlop for touch, kPrecisePointerHitSlop for a mouse.
          if (Math.abs(dx) <= (event.pointerType === "mouse" ? 1 : 18)) return;
          drag.dragging = true;
          track.setPointerCapture(event.pointerId);
        }
        thumb.style.left = `${offX + travel * Math.min(1, Math.max(0, drag.from + dx / travel))}px`;
      }}
      onPointerUp={release}
      onPointerCancel={release}
    >
      <span class="switch-thumb" ref={thumb} />
    </button>
  );
}
