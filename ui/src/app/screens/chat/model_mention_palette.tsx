// Port of lib/screens/chat/model_mention_palette.dart; mentionQuery, modelSelector and modelDisplayName are in
// composer_palettes.ts.
import { createEffect, For, Match, Switch } from "solid-js";
import type { RpcModel } from "../../../core/rpc/results";
import { t } from "../../i18n/i18n";
import { ActivityMark } from "../../widgets/activity_mark";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { modelDisplayName, modelSelector } from "./composer_palettes";
import { revealSelected } from "./slash_palette";
import "./composer_palette.css";

/**
 * The `^` list above the composer: one dense row per model, its name and selector, up to ten at once with a visible
 * scrollbar when there are more. `models` is undefined while the list loads; `selected` is highlighted and kept in
 * view; tapping a row picks it.
 */
export function ModelMentionPalette(props: {
  readonly models: readonly RpcModel[] | undefined;
  /** Why the list could not load. */
  readonly error: unknown;
  readonly selected: number;
  readonly onPick: (model: RpcModel) => void;
}) {
  let list: HTMLDivElement | undefined;
  createEffect(
    () => [props.selected, props.models] as const,
    ([selected]) => revealSelected(list, selected),
  );
  return (
    <Switch>
      <Match when={props.error !== undefined}>
        <div class="composer-palette composer-palette-note">
          <span class="composer-palette-note-text">{t.chat.modelsFailed({ error: String(props.error) })}</span>
        </div>
      </Match>
      <Match when={props.models === undefined}>
        <div class="composer-palette composer-palette-note">
          <ActivityMark />
        </div>
      </Match>
      <Match when={props.models}>
        {(models) => (
          <div class="composer-palette" role="listbox" ref={list}>
            <For each={models()}>
              {(model, index) => (
                <button
                  type="button"
                  class={["composer-palette-row", { "composer-palette-row-selected": index() === props.selected }]}
                  role="option"
                  aria-selected={index() === props.selected ? "true" : "false"}
                  data-ripple
                  // The composer keeps the focus, so typing goes on.
                  onPointerDown={(event) => event.preventDefault()}
                  onClick={() => props.onPick(model)}
                >
                  <Icon icon={Symbols.auto_awesome} size={16} class="composer-palette-icon" />
                  <span class="composer-palette-name composer-palette-model">{modelDisplayName(model)}</span>
                  <span class="composer-palette-selector">{modelSelector(model)}</span>
                </button>
              )}
            </For>
          </div>
        )}
      </Match>
    </Switch>
  );
}
