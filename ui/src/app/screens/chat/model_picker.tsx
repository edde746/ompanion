// Port of lib/screens/chat/model_picker.dart. ToolbarButton and the menu above the composer are in composer_toolbar.tsx,
// filterModels in composer_palettes.ts.
import { createMemo, createSignal, For, Show } from "solid-js";
import type { RpcModel } from "../../../core/rpc/results";
import type { LiveSession } from "../../../core/session/live_session";
import { type ModelRef, modelRefSelector } from "../../../core/store/session_view";
import { useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import { isDesktop } from "../../platform";
import { formatTokens } from "../../utils/token_count";
import { ActivityMark } from "../../widgets/activity_mark";
import { AppSearchField } from "../../widgets/app_search_field";
import { IconButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { filterModels } from "./composer_palettes";
import { ComposerMenu, ToolbarButton } from "./composer_toolbar";
import "./model_picker.css";

/** The widest the model list gets; narrower where the composer is. */
const listMaxWidth = 440;

/**
 * The composer's model button: opens a searchable list of the machine's models above the composer and switches
 * `session` to the picked one (RPC `set_model`, this session only).
 */
export function ModelPicker(props: {
  readonly session: LiveSession;
  readonly machine: Machine | undefined;
  readonly model: ModelRef | undefined;
}) {
  const sessions = useSessions();
  const [open, setOpen] = createSignal(false);
  // The button's ref writes it while the picker renders.
  const [button, setButton] = createSignal<HTMLButtonElement | undefined>(undefined, { ownedWrite: true });

  async function pick(picked: RpcModel) {
    setOpen(false);
    try {
      await props.session.rpc.setModel(picked.provider, picked.id);
    } catch (error) {
      showSnackBar(t.chat.modelFailed({ error: String(error) }));
    }
  }

  return (
    <>
      <ToolbarButton
        icon={Symbols.auto_awesome}
        label={props.model === undefined ? t.chat.noModel : (props.model.name ?? props.model.id)}
        tooltip={props.model === undefined ? undefined : modelRefSelector(props.model)}
        ref={setButton}
        onClick={props.machine === undefined ? undefined : () => setOpen(!open())}
      />
      <ComposerMenu
        open={open() && props.machine !== undefined}
        onClose={() => setOpen(false)}
        button={button()}
        maxWidth={listMaxWidth}
        fill
        label={t.chat.searchModels}
      >
        <ModelList
          load={(refresh) => sessions.models(props.machine!, props.session.rpc, { refresh })}
          current={props.model}
          onPick={(picked) => void pick(picked)}
        />
      </ComposerMenu>
    </>
  );
}

type Loaded =
  | { readonly kind: "loading" }
  | { readonly kind: "loaded"; readonly models: readonly RpcModel[] }
  | { readonly kind: "failed"; readonly error: unknown };

/**
 * The searchable list of models: a search row (field and refresh) over the models grouped by provider, as tall as
 * they are up to the menu's height; a longer list scrolls and the search row stays.
 */
function ModelList(props: {
  readonly load: (refresh: boolean) => Promise<RpcModel[]>;
  readonly current: ModelRef | undefined;
  readonly onPick: (model: RpcModel) => void;
}) {
  const [query, setQuery] = createSignal("");
  const [loaded, setLoaded] = createSignal<Loaded>({ kind: "loading" });
  let request = 0;

  function load(refresh: boolean) {
    const mine = ++request;
    // The first load starts in the body, where the list already reads as loading.
    if (refresh) setLoaded({ kind: "loading" });
    props.load(refresh).then(
      (models) => {
        if (mine === request) setLoaded({ kind: "loaded", models });
      },
      (error: unknown) => {
        if (mine === request) setLoaded({ kind: "failed", error });
      },
    );
  }
  load(false);

  const shown = createMemo(() => {
    const current = loaded();
    return current.kind === "loaded" ? filterModels(current.models, query()) : [];
  });
  const message = () => {
    const current = loaded();
    if (current.kind === "failed") return t.chat.modelsFailed({ error: String(current.error) });
    return current.kind === "loaded" && shown().length === 0 ? t.chat.noModels : undefined;
  };
  const isCurrent = (model: RpcModel) =>
    props.current !== undefined && props.current.provider === model.provider && props.current.id === model.id;

  return (
    <div class="model-picker-list">
      <div class="model-picker-search">
        {/* On iOS and Android focus would raise the on-screen keyboard over most of the list, which is there to be tapped. */}
        <AppSearchField hint={t.chat.searchModels} autofocus={isDesktop()} onChanged={setQuery} />
        <IconButton icon={Symbols.refresh} iconSize={18} size={36} tooltip={t.chat.refreshModels} onClick={() => load(true)} />
      </div>
      <Show
        when={loaded().kind !== "loading"}
        fallback={
          <div class="model-picker-message">
            <ActivityMark size={20} />
          </div>
        }
      >
        <Show when={message() === undefined} fallback={<div class="model-picker-message">{message()}</div>}>
          <div class="model-picker-rows">
            <For each={shown()}>
              {(model, index) => (
                <>
                  <Show when={index() === 0 || shown()[index() - 1]?.provider !== model.provider}>
                    <div class="model-picker-provider">{model.provider}</div>
                  </Show>
                  <button
                    type="button"
                    class={["model-picker-row", { "model-picker-row-selected": isCurrent(model) }]}
                    role="menuitemradio"
                    aria-checked={isCurrent(model) ? "true" : "false"}
                    data-ripple
                    onClick={() => props.onPick(model)}
                  >
                    <span class="model-picker-row-text">
                      <span class="model-picker-row-name">{model.name}</span>
                      <span class="model-picker-row-detail">
                        {[
                          model.id,
                          ...(model.contextWindow === undefined
                            ? []
                            : [t.chat.contextWindow({ tokens: formatTokens(model.contextWindow) })]),
                          ...(model.reasoning ? [t.chat.reasoning] : []),
                        ].join(" · ")}
                      </span>
                    </span>
                    <Show when={isCurrent(model)}>
                      <Icon icon={Symbols.check} size={18} />
                    </Show>
                  </button>
                </>
              )}
            </For>
          </div>
        </Show>
      </Show>
    </div>
  );
}
