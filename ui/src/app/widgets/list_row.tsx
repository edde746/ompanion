// The dense row of the sidebar and its kin (lib/screens/sessions/machine_sessions.dart, SidebarRow): `rowHeight` tall
// (44 px on touch screens), 8 px in from the pane's sides, a rounded hover and selection tone, no divider.
import type { JSX } from "@solidjs/web";
import "./list_row.css";
import { confirmRipple } from "./ripple";

export interface ListRowProps {
  readonly children: JSX.Element;
  readonly selected?: boolean;
  readonly onClick?: () => void;
  /** A secondary click or a long press, at a point in viewport px. */
  readonly onMenu?: (point: { x: number; y: number }) => void;
  /** Where the content starts inside the row: 8 px by default. */
  readonly indent?: number;
  readonly class?: string;
}

const longPressMs = 500;

export function ListRow(props: ListRowProps) {
  let pressTimer: ReturnType<typeof setTimeout> | undefined;
  let pressed = false;
  return (
    <div
      class={["list-row", { "list-row-selected": props.selected }, props.class]}
      data-ripple
      role="button"
      tabindex="0"
      aria-current={props.selected ? "true" : undefined}
      style={props.indent === undefined ? undefined : { "padding-left": `${props.indent}px` }}
      onClick={() => {
        if (pressed) {
          pressed = false;
          return;
        }
        props.onClick?.();
      }}
      onKeyDown={(event) => {
        if ((event.key === "Enter" || event.key === " ") && event.target === event.currentTarget) {
          event.preventDefault();
          props.onClick?.();
        }
      }}
      onContextMenu={(event) => {
        if (!props.onMenu) return;
        event.preventDefault();
        props.onMenu({ x: event.clientX, y: event.clientY });
      }}
      onPointerDown={(event) => {
        if (event.pointerType === "mouse" || !props.onMenu) return;
        const row = event.currentTarget.getBoundingClientRect();
        pressTimer = setTimeout(() => {
          pressed = true;
          confirmRipple();
          props.onMenu?.({ x: row.left + row.width / 2, y: row.top + row.height / 2 });
        }, longPressMs);
      }}
      onPointerUp={() => clearTimeout(pressTimer)}
      onPointerCancel={() => clearTimeout(pressTimer)}
      onPointerLeave={() => clearTimeout(pressTimer)}
    >
      {props.children}
    </div>
  );
}
