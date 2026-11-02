// lib/screens/machines/ssh_config_picker.dart.
import { createMemo, createSignal, Errored, For, Loading, Show } from "solid-js";
import { listSshConfigAliases } from "../../../core/ssh/openssh_config";
import { BridgeLink } from "../../../core/transport/bridge_link";
import { useKeys } from "../../app_state";
import { t } from "../../i18n/i18n";
import type { MachineDraft } from "../../models/machine_draft";
import { draftFromSshAlias } from "../../services/ssh_config_import";
import { ActivityMark } from "../../widgets/activity_mark";
import { TextButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { errorText } from "../config/config_widgets";
import "./ssh_config_picker.css";

/** Lists the `Host` aliases of `~/.ssh/config`; resolves with a draft resolved with `ssh -G` for the chosen one. */
export function showSshConfigPicker(): Promise<MachineDraft | undefined> {
  return showDialog<MachineDraft>((close) => <SshConfigPicker close={close} />);
}

async function sshConfigAliases(): Promise<string[]> {
  const local = new BridgeLink("local");
  try {
    return await listSshConfigAliases(await local.files());
  } finally {
    await local.close();
  }
}

function SshConfigPicker(props: { readonly close: (draft?: MachineDraft) => void }) {
  const keys = useKeys();
  const aliases = createMemo(() => sshConfigAliases());
  const [resolving, setResolving] = createSignal<string>();
  const [error, setError] = createSignal<string>();

  async function pick(alias: string) {
    setResolving(alias);
    setError(undefined);
    try {
      props.close(await draftFromSshAlias(alias, { keys: keys.keys() }));
    } catch (failure) {
      setResolving(undefined);
      setError(errorText(failure));
    }
  }

  return (
    <Dialog
      class="ssh-config-picker"
      title={t.sshConfig.title}
      actions={<TextButton onClick={() => props.close()}>{t.common.close}</TextButton>}
    >
      <Errored fallback={(failure) => <p>{t.sshConfig.failed({ error: errorText(failure()) })}</p>}>
        <Loading
          fallback={
            <div class="ssh-config-picker-loading">
              <ActivityMark size={20} />
            </div>
          }
        >
          <Show when={aliases().length > 0} fallback={<p>{t.sshConfig.empty}</p>}>
            <Show when={error()}>{(text) => <p class="ssh-config-picker-error">{text()}</p>}</Show>
            <For each={aliases()}>
              {(alias) => (
                <button
                  type="button"
                  data-ripple
                  class="ssh-config-picker-row"
                  disabled={resolving() !== undefined}
                  onClick={() => void pick(alias)}
                >
                  <Icon icon={Symbols.dns} size={24} />
                  <span class="ssh-config-picker-alias">{alias}</span>
                  <Show when={resolving() === alias}>
                    <ActivityMark size={16} />
                  </Show>
                </button>
              )}
            </For>
          </Show>
        </Loading>
      </Errored>
    </Dialog>
  );
}
