// lib/screens/dock/dock_empty_state.dart.
import type { JSX } from "@solidjs/web";
import { Show } from "solid-js";
import { Icon } from "../../widgets/icon";
import "./dock_empty_state.css";

/** An icon and a line of text, centered: what a dock tab shows when it has nothing to show. */
export function DockEmptyState(props: { readonly icon: string; readonly message: string; readonly action?: JSX.Element }) {
  return (
    <div class="dock-empty-state">
      <Icon icon={props.icon} size={32} class="dock-empty-state-icon" />
      <p class="dock-empty-state-message">{props.message}</p>
      <Show when={props.action}>{props.action}</Show>
    </div>
  );
}
