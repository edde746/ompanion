// lib/screens/machines/transfer_dialogs.dart: export of the SSH machines to copy or save, and import of one.
import { createEffect, createSignal, For, Show, untrack } from "solid-js";
import { call } from "../../../bridge";
import { asJsonObject, boolean, FormatException, string } from "../../../core/rpc/json_fields";
import { BridgeLink } from "../../../core/transport/bridge_link";
import { useMachines } from "../../app_state";
import { joinPath } from "../../files/file_paths";
import { t } from "../../i18n/i18n";
import type { SshMachine } from "../../models/machine";
import type { HostKeyImportChange } from "../../models/machine_export";
import { FilledButton, TextButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { errorText } from "../config/config_widgets";
import "./transfer_dialogs.css";

/** Exports stay small: machine records and host keys only. */
const maxImportBytes = 1024 * 1024;

const exportFileName = "ompanion-machines.json";

/** Shows the export of every SSH machine, to copy or save. Secrets are never part of it. */
export function showExportMachinesDialog(): Promise<void> {
  return showDialog<void>((close) => <ExportDialog close={close} />).then(() => undefined);
}

export function showImportMachinesDialog(): Promise<void> {
  return showDialog<void>((close) => <ImportDialog close={close} />).then(() => undefined);
}

interface Status {
  readonly text: string;
  readonly failed: boolean;
}

/**
 * Offers `text` in the platform's save panel as `name` (`shell.saveFile` serves it from the core's cache directory);
 * resolves to whether the user saved it.
 */
async function saveFile(name: string, text: string): Promise<boolean> {
  const cache = string(asJsonObject(await call<unknown>("core.paths"), "core.paths"), "cache");
  const path = joinPath(cache, name);
  const local = new BridgeLink("local");
  try {
    const files = await local.files();
    await files.write(path, new TextEncoder().encode(text));
    try {
      const answer = await call<unknown>("shell.saveFile", { name, url: `cache/${name}` });
      return boolean(asJsonObject(answer, "shell.saveFile"), "saved");
    } finally {
      await files.remove(path);
    }
  } finally {
    await local.close();
  }
}

function ExportDialog(props: { readonly close: () => void }) {
  const provider = useMachines();
  // The machines when the dialog opened, as the Dart reads them before showing it.
  const machines = untrack(() =>
    provider.machines().filter((machine): machine is SshMachine => machine.kind === "SshMachine"),
  );
  const json = provider.exportJson(machines);
  const [status, setStatus] = createSignal<Status>();

  async function report(action: () => Promise<string | undefined>) {
    try {
      const done = await action();
      if (done !== undefined) setStatus({ text: done, failed: false });
    } catch (error) {
      setStatus({ text: errorText(error), failed: true });
    }
  }

  return (
    <Dialog
      class="transfer-dialogs-export"
      title={t.transfer.exportTitle}
      actions={
        <>
          <Show when={machines.length > 0}>
            <TextButton
              icon={Symbols.content_copy}
              onClick={() =>
                void report(async () => {
                  await call("shell.clipboardWrite", { text: await json });
                  return t.common.copied;
                })
              }
            >
              {t.common.copy}
            </TextButton>
            <TextButton
              icon={Symbols.download}
              onClick={() =>
                void report(async () => ((await saveFile(exportFileName, await json)) ? t.transfer.saved : undefined))
              }
            >
              {t.transfer.saveFile}
            </TextButton>
          </Show>
          <FilledButton onClick={() => props.close()}>{t.common.close}</FilledButton>
        </>
      }
    >
      <p>{machines.length === 0 ? t.transfer.exportNone : t.transfer.exportBody({ count: machines.length })}</p>
      <Show when={status()}>
        {(shown) => <p class={["transfer-dialogs-status", { "transfer-dialogs-failed": shown().failed }]}>{shown().text}</p>}
      </Show>
    </Dialog>
  );
}

function ImportDialog(props: { readonly close: () => void }) {
  const provider = useMachines();
  const [text, setText] = createSignal("");
  const [status, setStatus] = createSignal<Status>();
  const [busy, setBusy] = createSignal(false);
  const [changes, setChanges] = createSignal<readonly HostKeyImportChange[]>([]);
  const [confirmed, setConfirmed] = createSignal<ReadonlySet<HostKeyImportChange>>(new Set());
  let field!: HTMLTextAreaElement;
  let picker!: HTMLInputElement;

  // The field grows with its text from 6 to 12 lines (its CSS bounds), as the Dart's minLines and maxLines.
  createEffect(text, () => {
    field.style.height = "auto";
    field.style.height = `${field.scrollHeight}px`;
  });

  async function chooseFile(file: File) {
    if (file.size > maxImportBytes) {
      setStatus({ text: t.transfer.invalid({ error: t.keys.fileTooLarge }), failed: true });
      return;
    }
    setText(await file.text());
  }

  async function importText() {
    setBusy(true);
    try {
      const result = await provider.importJson(text());
      setStatus({ text: t.transfer.imported({ added: result.added, skipped: result.skipped }), failed: false });
      setChanges(result.hostKeyChanges);
      setConfirmed(new Set<HostKeyImportChange>());
    } catch (error) {
      if (!(error instanceof FormatException)) throw error;
      setStatus({ text: t.transfer.invalid({ error: error.message }), failed: true });
      setChanges([]);
    } finally {
      setBusy(false);
    }
  }

  async function trust(change: HostKeyImportChange) {
    await provider.trustImportedHostKeys(change);
    setConfirmed((set) => new Set([...set, change]));
  }

  return (
    <Dialog
      class="transfer-dialogs-import"
      title={t.transfer.importTitle}
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.close}</TextButton>
          <FilledButton disabled={busy()} onClick={() => void importText()}>
            {t.transfer.importAction}
          </FilledButton>
        </>
      }
    >
      <div class="transfer-dialogs-column">
        <p>{t.transfer.importHint}</p>
        <textarea
          ref={field}
          class="transfer-dialogs-text"
          value={text()}
          spellcheck={false}
          autocomplete="off"
          onInput={(event) => setText(event.currentTarget.value)}
        />
        <input
          ref={picker}
          type="file"
          accept=".json,application/json"
          hidden
          onChange={(event) => {
            const file = event.currentTarget.files?.[0];
            // Cleared, so choosing the same file again reads it again.
            event.currentTarget.value = "";
            if (file !== undefined) void chooseFile(file);
          }}
        />
        <div class="transfer-dialogs-start">
          <TextButton icon={Symbols.folder_open} disabled={busy()} onClick={() => picker.click()}>
            {t.common.chooseFile}
          </TextButton>
        </div>
        <Show when={status()}>
          {(shown) => <p class={{ "transfer-dialogs-failed": shown().failed }}>{shown().text}</p>}
        </Show>
        <Show when={changes().length > 0}>
          <div>
            <h3 class="transfer-dialogs-title">{t.transfer.hostKeysTitle}</h3>
            <p class="transfer-dialogs-small">{t.transfer.hostKeysBody}</p>
            <For each={changes()}>
              {(change) => (
                <HostKeyChangeTile
                  change={change}
                  confirmed={confirmed().has(change)}
                  onTrust={() => void trust(change)}
                />
              )}
            </For>
          </div>
        </Show>
      </div>
    </Dialog>
  );
}

/**
 * Keys an import would add for one host, marked as a change: what this device trusts now, what the import holds, and a
 * button that trusts them.
 */
function HostKeyChangeTile(props: {
  readonly change: HostKeyImportChange;
  readonly confirmed: boolean;
  readonly onTrust: () => void;
}) {
  return (
    <div class={["transfer-dialogs-change", { "transfer-dialogs-confirmed": props.confirmed }]}>
      <div class="transfer-dialogs-change-host">
        <Icon icon={Symbols.gpp_maybe} size={18} class="transfer-dialogs-change-icon" />
        <span class="transfer-dialogs-title">
          {props.change.port === 22 ? props.change.host : `${props.change.host}:${props.change.port}`}
        </span>
      </div>
      <span class="transfer-dialogs-label">{t.transfer.trustedHere}</span>
      <Show when={props.change.trusted.length === 0}>
        <span class="transfer-dialogs-small">{t.transfer.nothingTrusted}</span>
      </Show>
      <For each={props.change.trusted}>
        {(row) => <span class="transfer-dialogs-code">{`${row.keyType} ${row.fingerprint}`}</span>}
      </For>
      <span class="transfer-dialogs-label">{t.transfer.inImport}</span>
      <For each={props.change.imported}>
        {(row) => <span class="transfer-dialogs-code">{`${row.keyType} ${row.fingerprint}`}</span>}
      </For>
      <div class="transfer-dialogs-end">
        <Show
          when={props.confirmed}
          fallback={<FilledButton onClick={() => props.onTrust()}>{t.transfer.trustKeys}</FilledButton>}
        >
          <span class="transfer-dialogs-trusted">{t.transfer.keysTrusted}</span>
        </Show>
      </div>
    </div>
  );
}
