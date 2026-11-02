// The SSH keys section of the settings pane: the keys of this device, imported or generated here, with their public
// half to copy and a delete that names the machines still using the key.
import { For, Show } from "solid-js";
import { useKeys, useMachines } from "../../app_state";
import type { SshKeyRow } from "../../database/tables";
import { t } from "../../i18n/i18n";
import { machineHops } from "../../models/machine";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import * as Symbols from "../../widgets/symbols";
import { SettingsCard } from "../settings/settings_card";
import { copyPublicKey, showGenerateKeyDialog, showImportKeyDialog } from "./key_dialogs";
import "./keys_section.css";

export function KeysSection() {
  const keys = useKeys();
  const machines = useMachines();

  const remove = async (key: SshKeyRow) => {
    const users = machines
      .machines()
      .filter((machine) => machineHops(machine).some((hop) => hop.keyId === key.id))
      .map((machine) => machine.name);
    const body = [t.keys.deleteBody];
    if (users.length > 0) body.push(t.keys.deleteUsedBy({ machines: users.join(", ") }));
    const confirmed = await showDialog<boolean>((close) => (
      <Dialog
        title={t.keys.deleteTitle({ name: key.name })}
        actions={
          <>
            <TextButton onClick={() => close(false)}>{t.common.cancel}</TextButton>
            <FilledButton onClick={() => close(true)}>{t.common.delete}</FilledButton>
          </>
        }
      >
        <p class="keys-section-confirm">{body.join("\n\n")}</p>
      </Dialog>
    ));
    if (confirmed === true) await keys.delete(key);
  };

  return (
    <div class="keys-section">
      <h2 class="settings-pane-heading settings-pane-section">{t.keys.title}</h2>
      <SettingsCard>
        <Show when={keys.keys().length > 0} fallback={<p class="keys-section-empty">{t.keys.empty}</p>}>
          <For each={keys.keys()}>
            {(key) => (
              <div class="keys-section-key">
                <span class="settings-row-text">
                  <span class="settings-row-label">{key.name}</span>
                  <span class="settings-row-detail">{key.type}</span>
                  <span class="keys-section-fingerprint">{key.fingerprint}</span>
                </span>
                <IconButton
                  icon={Symbols.content_copy}
                  tooltip={t.keys.copyPublicKey}
                  onClick={() => void copyPublicKey(key)}
                />
                <IconButton icon={Symbols.delete} tooltip={t.common.delete} onClick={() => void remove(key)} />
              </div>
            )}
          </For>
        </Show>
      </SettingsCard>
      <div class="keys-section-actions">
        <FilledButton icon={Symbols.download} onClick={() => void showImportKeyDialog()}>
          {t.keys.import}
        </FilledButton>
        <TonalButton icon={Symbols.auto_awesome} onClick={() => void showGenerateKeyDialog()}>
          {t.keys.generate}
        </TonalButton>
      </div>
    </div>
  );
}
