// lib/screens/settings/settings_card.dart.
import type { JSX } from "@solidjs/web";
import { Show } from "solid-js";
import { Card } from "../../widgets/card";
import { Icon } from "../../widgets/icon";
import { Switch } from "../../widgets/switch";
import "./settings_card.css";

/** A surfaceContainer block with `cardRadius`, the settings pane's grouping; its rows' ink lands on its tone. */
export function SettingsCard(props: { readonly children: JSX.Element }) {
  return <Card>{props.children}</Card>;
}

/**
 * A link in a {@link SettingsCard}: the label, an optional muted line under it, and a 16 px mark at the end. One
 * control tall with 4 px above and below its text, taller when the label wraps or a detail line takes the second line,
 * so no label is ever cut. No start icon, no divider: the row is the whole target.
 */
export function SettingsLinkRow(props: {
  readonly label: string;
  readonly detail?: string;
  readonly trailing: string;
  readonly onClick: () => void;
}) {
  return (
    <button type="button" data-ripple class="settings-link-row" onClick={() => props.onClick()}>
      <span class="settings-row-text">
        <span class="settings-row-label">{props.label}</span>
        <Show when={props.detail}>{(detail) => <span class="settings-row-detail">{detail()}</span>}</Show>
      </span>
      <Icon icon={props.trailing} size={16} class="settings-link-row-mark" />
    </button>
  );
}

/** A setting that is on or off in a {@link SettingsCard}: the label, an optional muted line, the switch at the end. */
export function SettingsSwitchRow(props: {
  readonly label: string;
  readonly detail?: string;
  readonly value: boolean;
  /** Absent: the switch is disabled. */
  readonly onChanged?: (value: boolean) => void;
}) {
  return (
    <div class="settings-switch-row">
      <span class="settings-row-text">
        <span class="settings-row-label">{props.label}</span>
        <Show when={props.detail}>{(detail) => <span class="settings-row-detail">{detail()}</span>}</Show>
      </span>
      <Switch value={props.value} onChanged={props.onChanged} label={props.label} />
    </div>
  );
}
