// Port of lib/screens/config/model_picker.dart.
import { createMemo, createSignal, For, Show } from "solid-js";
import type { RpcModel } from "../../../core/rpc/results";
import { splitSelector, thinkingLevels } from "../../config/accounts";
import { t } from "../../i18n/i18n";
import type { ModelChooser, SessionsProvider } from "../../sessions/sessions_provider";
import { formatTokens } from "../../utils/token_count";
import { AppSearchField } from "../../widgets/app_search_field";
import { AppSelect } from "../../widgets/app_select";
import { TextButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import "./model_picker.css";

/**
 * Picks a model selector (`provider/id[:thinking]`) from omp's available models, or a typed one. Resolves undefined
 * when dismissed. [message] explains the choice above the list.
 */
export function pickModel(options: {
  models: readonly RpcModel[];
  title: string;
  message?: string;
  current?: string;
}): Promise<string | undefined> {
  return showDialog<string>((close) => <ModelPicker {...options} close={close} />);
}

/**
 * The [ModelChooser] a session opens with: omp cannot restore the model a session ran on, so the user picks the one
 * its conversation continues on from the machine's available models, or leaves it closed.
 */
export function resumeModelChooser(sessions: SessionsProvider): ModelChooser {
  return async (machine, missing) => {
    const control = await sessions.control(machine);
    const models = await sessions.models(machine, control.rpc);
    return pickModel({
      models,
      title: t.sessions.resumeModelTitle,
      message: t.sessions.resumeModelBody({ model: missing, machine: machine.name }),
    });
  };
}

function ModelPicker(props: {
  readonly models: readonly RpcModel[];
  readonly title: string;
  readonly message?: string;
  readonly current?: string;
  readonly close: (selector?: string) => void;
}) {
  const [query, setQuery] = createSignal("");
  const [thinking, setThinking] = createSignal(
    props.current === undefined ? undefined : splitSelector(props.current).thinking,
  );
  const choose = (model: string) => {
    const level = thinking();
    props.close(level === undefined ? model : `${model}:${level}`);
  };
  const matchesOf = (text: string) => {
    const words = text
      .toLowerCase()
      .split(/\s+/)
      .filter((word) => word !== "");
    return props.models
      .filter((model) => {
        const haystack = `${model.provider}/${model.id} ${model.name}`.toLowerCase();
        return words.every((word) => haystack.includes(word));
      })
      .sort((a, b) => {
        const left = `${a.provider}/${a.id}`;
        const right = `${b.provider}/${b.id}`;
        return left < right ? -1 : left > right ? 1 : 0;
      });
  };
  const matches = createMemo(() => matchesOf(query()));
  const typed = () => query().trim();
  const current = () => (props.current === undefined ? undefined : splitSelector(props.current).model);
  const offerTyped = () =>
    typed().includes("/") && !matches().some((model) => `${model.provider}/${model.id}` === typed());

  return (
    <Dialog
      title={props.title}
      class="config-model-picker"
      actions={<TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>}
    >
      <div class="config-model-picker-body">
        <Show when={props.message}>{(message) => <p class="config-model-picker-message">{message()}</p>}</Show>
        <div class="config-model-picker-controls">
          <AppSearchField
            class="config-model-picker-search"
            autofocus
            hint={t.config.roles.searchModels}
            onChanged={setQuery}
            onSubmitted={(text) => {
              const found = matchesOf(text);
              const only = found.length === 1 ? found[0] : undefined;
              if (only !== undefined) choose(`${only.provider}/${only.id}`);
            }}
          />
          <AppSelect
            value={thinking()}
            tooltip={t.config.roles.thinking}
            options={[
              [undefined, t.config.roles.thinkingDefault] as const,
              ...thinkingLevels.map((level) => [level, level] as const),
            ]}
            onChanged={setThinking}
          />
        </div>
        <div class="config-model-picker-list">
          <Show when={offerTyped()}>
            <button type="button" data-ripple class="config-model-picker-row" onClick={() => choose(typed())}>
              <Icon icon={Symbols.edit} size={20} />
              <span class="config-model-picker-row-text">
                <span class="config-model-picker-row-title">{t.config.roles.useTyped({ selector: typed() })}</span>
                <span class="config-model-picker-row-subtitle">{t.config.roles.useTypedHint}</span>
              </span>
            </button>
          </Show>
          <For each={matches()}>
            {(model) => (
              <button
                type="button"
                data-ripple
                class={[
                  "config-model-picker-row",
                  { "config-model-picker-row-selected": `${model.provider}/${model.id}` === current() },
                ]}
                onClick={() => choose(`${model.provider}/${model.id}`)}
              >
                <Icon icon={model.reasoning ? Symbols.neurology : Symbols.smart_toy} size={20} />
                <span class="config-model-picker-row-text">
                  <span class="config-model-picker-row-title">{model.name}</span>
                  <span class="config-model-picker-row-subtitle">
                    {[
                      `${model.provider}/${model.id}`,
                      ...(model.contextWindow === undefined
                        ? []
                        : [t.config.roles.context({ tokens: formatTokens(model.contextWindow) })]),
                      ...(model.input.includes("image") ? [t.config.roles.vision] : []),
                    ].join(" · ")}
                  </span>
                </span>
              </button>
            )}
          </For>
          <Show when={matches().length === 0 && !typed().includes("/")}>
            <p class="config-model-picker-empty">{t.config.roles.noModels}</p>
          </Show>
        </div>
      </div>
    </Dialog>
  );
}
