// lib/widgets/activity_mark.dart.
import { For, onSettled } from "solid-js";
import { activityStep, showActivityMark } from "./activity_clock";

/**
 * The frames of omp's TUI activity spinner, ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏, as their braille dot bits: bits 0 to 2 are the left column from
 * the top, bits 3 to 5 the right one.
 */
const frames = [0x0b, 0x19, 0x39, 0x38, 0x3c, 0x34, 0x26, 0x27, 0x07, 0x0f];

const dots = [0, 1, 2, 3, 4, 5];

/**
 * The app's one mark for work that is under way: omp's TUI activity spinner painted as a braille cell, two columns of
 * three dots in a `size` square (14 px in a line of text, 16 in a button, 20 centred in a pane that loads), the frame's
 * dots lit and the rest at 13 %, in the current text colour (onSurfaceVariant unless the slot has a status colour).
 * Every mark steps together from one clock. It stands still on the first frame when the device asks for less motion.
 */
export function ActivityMark(props: { readonly size?: number; readonly color?: string }) {
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  onSettled(() => (still ? undefined : showActivityMark()));
  const size = () => props.size ?? 14;
  const lit = (dot: number) => ((frames[still ? 0 : activityStep() % frames.length] ?? 0) & (1 << dot)) !== 0;
  return (
    <svg
      class="activity-mark"
      width={size()}
      height={size()}
      viewBox="0 0 10 10"
      role="progressbar"
      style={{ color: props.color ?? "var(--on-surface-variant)", flex: "none", display: "block" }}
    >
      <For each={dots}>
        {(dot) => (
          <circle
            cx={5 + (Math.floor(dot / 3) - 0.5) * 3}
            cy={5 + ((dot % 3) - 1) * 3}
            r={1}
            fill="currentColor"
            opacity={lit(dot) ? 1 : 0.13}
          />
        )}
      </For>
    </svg>
  );
}
