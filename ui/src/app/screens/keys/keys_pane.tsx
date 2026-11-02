// lib/screens/keys/keys_pane.dart.
import { For, Show } from "solid-js";
import { useKeys, useMachines } from "../../app_state";
import type { SshKeyRow } from "../../database/tables";
import { t } from "../../i18n/i18n";
import { machineHops } from "../../models/machine";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Card } from "../../widgets/card";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { copyPublicKey, showGenerateKeyDialog, showImportKeyDialog } from "./key_dialogs";
import "./keys_pane.css";

/** SSH keys of this device: import, generate, copy the public half, delete. */
export function KeysPane() {
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
        <p class="keys-pane-confirm">{body.join("\n\n")}</p>
      </Dialog>
    ));
    if (confirmed === true) await keys.delete(key);
  };

  return (
    <div class="keys-pane">
      <div class="keys-pane-actions">
        <FilledButton icon={Symbols.download} onClick={() => void showImportKeyDialog()}>
          {t.keys.import}
        </FilledButton>
        <TonalButton icon={Symbols.auto_awesome} onClick={() => void showGenerateKeyDialog()}>
          {t.keys.generate}
        </TonalButton>
      </div>
      <Show when={keys.keys().length > 0} fallback={<p class="keys-pane-empty">{t.keys.empty}</p>}>
        <div class="keys-pane-list">
          <For each={keys.keys()}>
            {(key) => (
              <Card class="keys-pane-key">
                <div class="keys-pane-row">
                  <Icon icon={Symbols.key} class="keys-pane-icon" />
                  <div class="keys-pane-text">
                    <span class="keys-pane-name">{key.name}</span>
                    <span class="keys-pane-type">{key.type}</span>
                    <span class="keys-pane-fingerprint">{key.fingerprint}</span>
                  </div>
                  <IconButton
                    icon={Symbols.content_copy}
                    tooltip={t.keys.copyPublicKey}
                    onClick={() => void copyPublicKey(key)}
                  />
                  <IconButton icon={Symbols.delete} tooltip={t.common.delete} onClick={() => void remove(key)} />
                </div>
              </Card>
            )}
          </For>
        </div>
      </Show>
    </div>
  );
}
