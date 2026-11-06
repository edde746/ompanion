// lib/screens/keys/key_dialogs.dart.
import { createSignal, Show, untrack } from "solid-js";
import { call } from "../../../bridge";
import { hostPath, toSftpPath } from "../../../core/host/scripts";
import { asJsonObject, optString } from "../../../core/rpc/json_fields";
import { BridgeLink } from "../../../core/transport/bridge_link";
import { useKeys } from "../../app_state";
import type { SshKeyRow } from "../../database/tables";
import { baseName } from "../../files/file_paths";
import { t } from "../../i18n/i18n";
import { coreInfo, pickFiles, shellInfo } from "../../platform";
import { thisComputerAvailable } from "../../services/machine_connector";
import { FilledButton, TextButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { LabeledField } from "../../widgets/labeled_field";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { describeKeyError, keyFileText, maxKeyFileBytes, readKeyFile } from "./key_import";
import "./key_dialogs.css";

/** Imports a pasted or picked private key. Resolves with the stored key, or undefined when cancelled. */
export function showImportKeyDialog(): Promise<SshKeyRow | undefined> {
  const [busy, setBusy] = createSignal(false);
  // Escape, the scrim and back wait like Cancel while the key is stored: it is stored either way.
  return showDialog<SshKeyRow>((close) => <ImportKeyDialog busy={busy()} setBusy={setBusy} close={close} />, {
    dismissible: () => !busy(),
  });
}

/** Generates an Ed25519 key and shows its public half. Resolves with the stored key, or undefined when cancelled. */
export function showGenerateKeyDialog(): Promise<SshKeyRow | undefined> {
  const [busy, setBusy] = createSignal(false);
  // As the import: a key being generated is stored either way.
  return showDialog<SshKeyRow>((close) => <GenerateKeyDialog busy={busy()} setBusy={setBusy} close={close} />, {
    dismissible: () => !busy(),
  });
}

interface KeyDialogProps {
  readonly busy: boolean;
  readonly setBusy: (busy: boolean) => void;
  readonly close: (key?: SshKeyRow) => void;
}

export async function copyPublicKey(key: SshKeyRow): Promise<void> {
  await call("shell.clipboardWrite", { text: key.publicKey });
  showSnackBar(t.keys.publicKeyCopied);
}

function ImportKeyDialog(props: KeyDialogProps) {
  const keys = useKeys();
  const [name, setName] = createSignal("");
  const [pem, setPem] = createSignal("");
  const [passphrase, setPassphrase] = createSignal("");
  const [nameMissing, setNameMissing] = createSignal(false);
  const [pemMissing, setPemMissing] = createSignal(false);
  const [error, setError] = createSignal<string>();
  let fileInput: HTMLInputElement | undefined;

  const take = (read: { text: string } | { error: string }, fileName: string) => {
    if ("error" in read) {
      setError(read.error);
      return;
    }
    setError(undefined);
    setPem(read.text);
    if (name().trim() === "") setName(fileName);
  };

  /**
   * A desktop shell's open panel, in `~/.ssh` where the build reaches the user's home, as the Flutter app's file picker
   * opened; elsewhere the page's file input.
   */
  const chooseFile = async () => {
    if (!shellInfo().paths) {
      fileInput?.click();
      return;
    }
    const home = thisComputerAvailable()
      ? optString(asJsonObject(await call<unknown>("core.paths"), "core.paths"), "home")
      : undefined;
    const [path] = await pickFiles({ startIn: home === undefined ? undefined : hostPath(`${home}/.ssh`) });
    if (path === undefined) return;
    const at = toSftpPath(path);
    const local = new BridgeLink("local");
    try {
      // One byte past the limit tells a key file from a larger one.
      take(keyFileText(await (await local.files()).read(at, { length: maxKeyFileBytes + 1 })), baseName(at));
    } finally {
      await local.close();
    }
  };

  const submit = async () => {
    const noName = name().trim() === "";
    const noPem = pem().trim() === "";
    setNameMissing(noName);
    setPemMissing(noPem);
    if (noName || noPem) return;
    props.setBusy(true);
    setError(undefined);
    try {
      const key = await keys.importKey({
        name: name().trim(),
        pem: pem(),
        passphrase: passphrase() === "" ? undefined : passphrase(),
      });
      props.close(key);
    } catch (failure) {
      props.setBusy(false);
      setError(describeKeyError(failure));
    }
  };

  return (
    <Dialog
      class="key-dialogs-import"
      title={t.keys.importTitle}
      actions={
        <>
          <TextButton disabled={props.busy} onClick={() => props.close()}>
            {t.common.cancel}
          </TextButton>
          <FilledButton disabled={props.busy} onClick={() => void submit()}>
            {t.keys.importAction}
          </FilledButton>
        </>
      }
    >
      <div class="key-dialogs-form">
        <LabeledField label={t.keys.name} error={nameMissing() ? t.common.required : undefined}>
          <TextField value={name()} onInput={setName} autofocus />
        </LabeledField>
        <LabeledField label={t.keys.privateKey} error={pemMissing() ? t.common.required : undefined}>
          <textarea
            class="key-dialogs-pem"
            rows={4}
            value={pem()}
            placeholder={t.keys.privateKeyHint}
            spellcheck="false"
            autocomplete="off"
            autocapitalize="off"
            onInput={(event) => setPem(event.currentTarget.value)}
          />
        </LabeledField>
        <div class="key-dialogs-file">
          <TextButton
            icon={Symbols.folder_open}
            disabled={props.busy}
            onClick={() => void chooseFile().catch((failure: unknown) => setError(String(failure)))}
          >
            {t.common.chooseFile}
          </TextButton>
          <input
            ref={fileInput}
            type="file"
            hidden
            onChange={(event) => {
              const file = event.currentTarget.files?.[0];
              event.currentTarget.value = "";
              if (file !== undefined) void readKeyFile(file).then((read) => take(read, file.name));
            }}
          />
        </div>
        <LabeledField label={t.keys.passphrase}>
          <TextField
            type="password"
            value={passphrase()}
            onInput={setPassphrase}
            onSubmit={() => {
              if (!props.busy) void submit();
            }}
          />
          <span class="key-dialogs-helper">{t.keys.passphraseHint}</span>
        </LabeledField>
        <Show when={error()}>{(message) => <p class="key-dialogs-error">{message()}</p>}</Show>
      </div>
    </Dialog>
  );
}

function GenerateKeyDialog(props: KeyDialogProps) {
  const keys = useKeys();
  // The device name as the default, so an `authorized_keys` line tells which device holds the key.
  const [name, setName] = createSignal(
    untrack(() => {
      const info = coreInfo();
      return info !== undefined && "hostname" in info && typeof info.hostname === "string" ? info.hostname : "";
    }),
  );
  const [nameMissing, setNameMissing] = createSignal(false);
  const [generated, setGenerated] = createSignal<SshKeyRow>();
  const [error, setError] = createSignal<string>();

  const generate = async () => {
    const noName = name().trim() === "";
    setNameMissing(noName);
    if (noName) return;
    props.setBusy(true);
    try {
      setGenerated(await keys.generateEd25519({ name: name().trim() }));
    } catch (failure) {
      setError(String(failure));
    } finally {
      props.setBusy(false);
    }
  };

  return (
    <Show
      when={generated()}
      fallback={
        <Dialog
          class="key-dialogs-generate"
          title={t.keys.generateTitle}
          actions={
            <>
              <TextButton disabled={props.busy} onClick={() => props.close()}>
                {t.common.cancel}
              </TextButton>
              <FilledButton disabled={props.busy} onClick={() => void generate()}>
                {t.keys.generateAction}
              </FilledButton>
            </>
          }
        >
          <div class="key-dialogs-form">
            <LabeledField label={t.keys.name} error={nameMissing() ? t.common.required : undefined}>
              <TextField
                value={name()}
                onInput={setName}
                autofocus
                onSubmit={() => {
                  if (!props.busy) void generate();
                }}
              />
            </LabeledField>
            <Show when={error()}>{(message) => <p class="key-dialogs-error">{message()}</p>}</Show>
          </div>
        </Dialog>
      }
    >
      {(key) => (
        <Dialog
          class="key-dialogs-generated"
          title={key().name}
          actions={
            <>
              <TextButton icon={Symbols.content_copy} onClick={() => void copyPublicKey(key())}>
                {t.keys.copyPublicKey}
              </TextButton>
              <FilledButton onClick={() => props.close(key())}>{t.common.close}</FilledButton>
            </>
          }
        >
          <div class="key-dialogs-form">
            <p class="key-dialogs-body">{t.keys.generatedBody}</p>
            <p class="key-dialogs-public">{key().publicKey}</p>
          </div>
        </Dialog>
      )}
    </Show>
  );
}
