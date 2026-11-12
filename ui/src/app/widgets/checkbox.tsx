// The theme's Checkbox and Radio: onSurface when selected, onSurfaceVariant when not; a checked box's mark in the
// surface colour. Both move as toggleable.dart's controls do: over _kToggleDuration along Curves.easeIn (easeOut
// backwards, which plays as easeIn either way). The checkbox is drawn as material/checkbox.dart paints it, so its fill
// and the strokes of its check mark can animate. CheckboxMark and RadioMark are the glyphs alone, in currentColor, for
// a row that is the control itself (the ask form's options).
import { createEffect, createMemo } from "solid-js";
import { Curves, curveFrames, play, settled } from "../motion";
import "./checkbox.css";

export interface CheckboxProps {
  readonly value: boolean;
  /** Absent: disabled. */
  readonly onChanged?: (value: boolean) => void;
  readonly label?: string;
}

/** toggleable.dart's _kToggleDuration. */
const toggleMs = 200;
/** The check mark's short stroke as a share of its length: (0.15, 0.45) → (0.4, 0.7) of 0.7 in all. */
const shortStroke = 0.25 / 0.7;

/**
 * _CheckboxPainter.paint at t (0 unchecked, 1 checked), for the four parts: the box shrinks by a stroke's width at
 * t = 0.5 and back, its fill comes in over the first quarter, its border thins out over the first half, and the check
 * mark draws its short stroke and then its long one over the second half.
 */
function checkboxFrames(checked: boolean) {
  const t = (s: number) => (checked ? Curves.easeIn(s) : Curves.easeOut(1 - s));
  return {
    shape: curveFrames(t, (value) => ({ transform: `scale(${(18 - 2 * (1 - Math.abs(value - 0.5) * 2)) / 18})` })),
    fill: curveFrames(t, (value) => ({ fillOpacity: Math.min(1, value * 4) })),
    frame: curveFrames(t, (value) => ({
      strokeWidth: value <= 0.5 ? 2 * (1 - value) : 0,
      strokeOpacity: value <= 0.5 ? 1 - value : 0,
    })),
    check: curveFrames(t, (value) => {
      const drawn = value <= 0.5 ? 0 : (value - 0.5) * 2;
      const length = drawn < 0.5 ? drawn * 2 * shortStroke : shortStroke + (drawn * 2 - 1) * (1 - shortStroke);
      return { strokeDashoffset: 1 - length };
    }),
  };
}

/** The checkbox's 18 px glyph in currentColor, without a target of its own. */
export function CheckboxMark(props: { readonly checked: boolean }) {
  let shape!: SVGGElement;
  let fill!: SVGRectElement;
  let frame!: SVGRectElement;
  let check!: SVGPathElement;
  let motion: Animation[] = [];
  // An effect runs each time its compute does, equal value or not, and the value is often read from a whole answer
  // (`selected.includes(label)`): a memo passes on only a change, so only the box that turned animates.
  const checked = createMemo(() => props.checked);
  createEffect(
    checked,
    (value) => {
      for (const animation of motion) animation.cancel();
      const frames = checkboxFrames(value);
      motion = [
        play(shape, frames.shape, toggleMs),
        play(fill, frames.fill, toggleMs),
        play(frame, frames.frame, toggleMs),
        play(check, frames.check, toggleMs),
      ];
      const current = motion;
      // Once drawn, the stylesheet's resting state is the last frame.
      void settled(current[0]!).then((finished) => {
        if (finished) for (const animation of current) animation.cancel();
      });
    },
    { defer: true },
  );
  return (
    <svg
      class={["checkbox-box", { "checkbox-box-checked": props.checked }]}
      width="18"
      height="18"
      viewBox="0 0 18 18"
      aria-hidden="true"
    >
      <g class="checkbox-shape" ref={shape}>
        <rect class="checkbox-fill" width="18" height="18" rx="2" ref={fill} />
        <rect class="checkbox-frame" x="1" y="1" width="16" height="16" rx="1" ref={frame} />
      </g>
      <path class="checkbox-check" d="M2.7 8.1 7.2 12.6 15.3 4.5" pathLength="1" ref={check} />
    </svg>
  );
}

export function Checkbox(props: CheckboxProps) {
  return (
    <button
      type="button"
      role="checkbox"
      aria-checked={props.value ? "true" : "false"}
      aria-label={props.label}
      class={["checkbox", { "checkbox-checked": props.value }]}
      disabled={!props.onChanged}
      onClick={() => props.onChanged?.(!props.value)}
    >
      <CheckboxMark checked={props.value} />
    </button>
  );
}

export interface RadioProps {
  readonly selected: boolean;
  /** Absent: disabled. */
  readonly onSelected?: () => void;
  readonly label?: string;
}

/** The radio's 20 px ring in currentColor, without a target of its own. */
export function RadioMark(props: { readonly selected: boolean }) {
  return <span class={["radio-ring", { "radio-ring-selected": props.selected }]} aria-hidden="true" />;
}

export function Radio(props: RadioProps) {
  return (
    <button
      type="button"
      role="radio"
      aria-checked={props.selected ? "true" : "false"}
      aria-label={props.label}
      class={["radio", { "radio-selected": props.selected }]}
      disabled={!props.onSelected}
      onClick={() => props.onSelected?.()}
    >
      <RadioMark selected={props.selected} />
    </button>
  );
}
