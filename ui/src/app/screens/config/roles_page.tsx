// Port of lib/screens/config/roles_page.dart; its state is RolesPageState (roles_page_state.ts).
import { For, onSettled, Show, untrack } from "solid-js";
import type { RpcModel } from "../../../core/rpc/results";
import type { ModelRole } from "../../config/accounts";
import type { ConfigTarget } from "../../config/config_target";
import { t } from "../../i18n/i18n";
import { ActivityMark } from "../../widgets/activity_mark";
import { IconButton, TextButton } from "../../widgets/button";
import * as Symbols from "../../widgets/symbols";
import {
  ConfigBlock,
  ConfigError,
  ConfigHeader,
  ConfigSectionTitle,
  ProvenanceBadge,
  RefreshAction,
  runReporting,
} from "./config_widgets";
import { pickModel } from "./model_picker";
import "./roles_page.css";
import { RolesPageState } from "./roles_page_state";

export function RolesPage(props: { readonly target: ConfigTarget }) {
  const state = new RolesPageState(untrack(() => props.target));
  onSettled(() => {
    void state.load();
    return () => state.dispose();
  });
  const project = () => props.target.projectSession();

  const assign = async (role: ModelRole, options: { project: boolean }) => {
    let models: RpcModel[] = [];
    if (!(await runReporting(async () => (models = await state.models())))) return;
    const selector = await pickModel({
      models,
      title: t.config.roles.pickTitle({ role: role.name }),
      current: options.project ? role.project : role.global,
    });
    if (selector === undefined) return;
    await runReporting(() => state.set(role, selector, options));
  };

  const subtitle = () => {
    const roles = state.roles();
    if (roles === undefined) return undefined;
    const session = project();
    return [
      t.config.roles.storage({ storage: roles.storage }),
      session === undefined ? t.config.roles.noProject : t.config.roles.projectIs({ path: session.cwd }),
    ].join("\n");
  };

  return (
    <div class="config-page-body">
      <ConfigHeader
        title={t.config.sections.roles}
        subtitle={subtitle()}
        actions={
          <>
            <TextButton
              icon={Symbols.sync}
              onClick={() =>
                void runReporting(() => state.models({ refresh: true }), { done: t.config.roles.modelsRefreshed })
              }
            >
              {t.config.roles.refreshModels}
            </TextButton>
            <RefreshAction loading={state.loading()} onPressed={() => void state.load()} />
          </>
        }
      />
      <Show
        when={state.roles()}
        fallback={
          <div class="roles-page-center">
            <Show when={state.error() !== undefined} fallback={<ActivityMark size={20} />}>
              <ConfigError error={state.error()} onRetry={() => void state.load()} />
            </Show>
          </div>
        }
      >
        {(roles) => (
          <div class="config-list">
            <For each={[false, true]}>
              {(kind) => (
                <>
                  <ConfigSectionTitle text={kind ? t.config.roles.kindRoles : t.config.roles.chatRoles} />
                  <For each={roles().roles.filter((role) => role.kindSection === kind)}>
                    {(role) => (
                      <RoleCard
                        role={role}
                        busy={state.busy().has(role.role)}
                        projectAvailable={project() !== undefined}
                        onAssign={(inProject) => void assign(role, { project: inProject })}
                        onClear={(inProject) =>
                          void runReporting(() => state.set(role, undefined, { project: inProject }))
                        }
                      />
                    )}
                  </For>
                </>
              )}
            </For>
          </div>
        )}
      </Show>
    </div>
  );
}

function RoleCard(props: {
  readonly role: ModelRole;
  readonly busy: boolean;
  readonly projectAvailable: boolean;
  readonly onAssign: (project: boolean) => void;
  readonly onClear: (project: boolean) => void;
}) {
  const layer = (label: string, value: string | undefined, project: boolean, available: boolean) => (
    <div class="roles-page-row">
      <span class="roles-page-row-label">{label}</span>
      <span class={["roles-page-row-value", { "roles-page-auto": value === undefined }]}>
        {value ?? t.config.roles.auto}
      </span>
      <TextButton disabled={!available || props.busy} onClick={() => props.onAssign(project)}>
        {t.config.roles.assign}
      </TextButton>
      {/* Full tone like Set beside it: the default grey of an enabled icon is too close to a disabled one. */}
      <IconButton
        class="roles-page-clear"
        icon={Symbols.close}
        iconSize={18}
        tooltip={t.config.roles.clear}
        disabled={!available || props.busy || value === undefined}
        onClick={() => props.onClear(project)}
      />
    </div>
  );
  return (
    <ConfigBlock class="roles-page-card" padding="8px 4px 4px 12px">
      <div class="roles-page-heading">
        <span class="roles-page-name">{props.role.name}</span>
        <span class="roles-page-id">{props.role.role}</span>
        <Show when={props.busy}>
          <ActivityMark size={16} />
        </Show>
      </div>
      <div class="roles-page-effective">
        <span class="roles-page-row-label">{t.config.roles.effective}</span>
        <span class={["roles-page-effective-value", { "roles-page-mono": props.role.model !== undefined }]}>
          {props.role.model ?? t.config.roles.auto}
        </span>
        <ProvenanceBadge provenance={props.role.provenance} />
      </div>
      {layer(t.config.scope.global, props.role.global, false, true)}
      {layer(t.config.roles.projectLayer, props.role.project, true, props.projectAvailable)}
    </ConfigBlock>
  );
}
