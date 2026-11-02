// A known fraction (install progress, an upload's bytes): a bar or a ring that moves only when the count does. Work of
// unknown length shows the ActivityMark instead (docs/design.md: no indeterminate indicators).
import "./progress.css";

/** A 4 px track in surfaceContainerHighest filled to `value` (0 to 1) in onSurfaceVariant. */
export function LinearProgress(props: { readonly value: number }) {
  const fraction = () => Math.min(1, Math.max(0, props.value));
  return (
    <div
      class="linear-progress"
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={String(Math.round(fraction() * 100))}
    >
      <div class="linear-progress-fill" style={{ width: `${fraction() * 100}%` }} />
    </div>
  );
}

/** A ring `size` px across, its arc drawn to `value` (0 to 1) in onSurfaceVariant on no track. */
export function RingProgress(props: { readonly value: number; readonly size?: number }) {
  const fraction = () => Math.min(1, Math.max(0, props.value));
  const radius = 18;
  const circumference = 2 * Math.PI * radius;
  return (
    <svg
      class="ring-progress"
      width={props.size ?? 40}
      height={props.size ?? 40}
      viewBox="0 0 40 40"
      role="progressbar"
      aria-valuemin="0"
      aria-valuemax="100"
      aria-valuenow={String(Math.round(fraction() * 100))}
    >
      <circle
        cx="20"
        cy="20"
        r={radius}
        fill="none"
        stroke="currentColor"
        stroke-width="4"
        stroke-dasharray={`${fraction() * circumference} ${circumference}`}
        transform="rotate(-90 20 20)"
      />
    </svg>
  );
}
