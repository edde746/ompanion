// lib/screens/machines/machine_editor.dart: adds a machine, or edits one.
import { createSignal, flush, For, onSettled, Show, untrack } from "solid-js";
import { useKeys, useMachines, useSecrets, useShell } from "../../app_state";
import type { AuthMethod, MachineKind } from "../../database/tables";
import { t } from "../../i18n/i18n";
import type { Machine } from "../../models/machine";
import type { MachineDraft } from "../../models/machine_draft";
import { isDesktop } from "../../platform";
import { thisComputerAvailable } from "../../services/machine_connector";
import { newId } from "../../utils/ids";
import { AppSegmented } from "../../widgets/app_segmented";
import { AppSelect } from "../../widgets/app_select";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import { Checkbox } from "../../widgets/checkbox";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import { LabeledField } from "../../widgets/labeled_field";
import { showSnackBar } from "../../widgets/snackbar";
import { Switch } from "../../widgets/switch";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { errorText } from "../config/config_widgets";
import { showGenerateKeyDialog, showImportKeyDialog } from "../keys/key_dialogs";
import { compactWidthBelow } from "../shell/layout";
import {
  blankHop,
  defaultAuth,
  editorSave,
  type FormErrors,
  formErrors,
  formWithDraft,
  type HopErrors,
  type HopForm,
  machineForm,
  type MachineForm,
} from "./machine_editor_form";
import "./machine_editor.css";
import { showSshConfigPicker } from "./ssh_config_picker";
import { showTailscalePicker } from "./tailscale_picker";

const authMethods: readonly AuthMethod[] = ["key", "password", "agent", "none", "keyboardInteractive"];

/** Adds a machine, or edits `machine`. A new machine is selected after saving. */
export function showMachineEditor(options: { readonly machine?: Machine } = {}): Promise<void> {
  const [saving, setSaving] = createSignal(false);
  // Escape, the scrim and back wait like Cancel while the machine is stored: it is saved and selected either way.
  return showDialog<void>(
    (close) => <EditorAfterKeys machine={options.machine} saving={saving()} setSaving={setSaving} close={close} />,
    { dismissible: () => !saving() },
  ).then(() => undefined);
}

interface EditorProps {
  readonly machine: Machine | undefined;
  readonly saving: boolean;
  readonly setSaving: (saving: boolean) => void;
  readonly close: () => void;
}

export function authLabel(method: AuthMethod): string {
  switch (method) {
    case "key":
      return t.auth.key;
    case "password":
      return t.auth.password;
    case "agent":
      return t.auth.agent;
    case "none":
      return t.auth.none;
    case "keyboardInteractive":
      return t.auth.keyboardInteractive;
  }
}

/** A new hop's default auth depends on whether keys are stored, so the editor waits for them. */
function EditorAfterKeys(props: EditorProps) {
  const keys = useKeys();
  const [ready, setReady] = createSignal(false);
  onSettled(
    () =>
      void keys.ready.then(
        () => setReady(true),
        (error: unknown) => {
          showSnackBar(errorText(error));
          props.close();
        },
      ),
  );
  return (
    <Show when={ready()}>
      <MachineEditor machine={props.machine} saving={props.saving} setSaving={props.setSaving} close={props.close} />
    </Show>
  );
}

function MachineEditor(props: EditorProps) {
  const machines = useMachines();
  const keys = useKeys();
  const shell = useShell();
  const secrets = useSecrets();
  const editing = untrack(() => props.machine);
  const newHopAuth = () => defaultAuth({ keys: keys.keys(), desktop: isDesktop() });
  const [form, setForm] = createSignal<MachineForm>(
    untrack(() =>
      machineForm({
        machine: editing,
        id: newId(),
        auth: newHopAuth(),
        localFirst: thisComputerAvailable() && !machines.hasLocal(),
      }),
    ),
  );
  const [errors, setErrors] = createSignal<FormErrors>();
  const canChooseKind = () => editing === undefined && thisComputerAvailable() && !machines.hasLocal();
  /** The name field and each hop's fields, to scroll the first one with an error into view. */
  const anchors = new Map<string, HTMLElement>();
  let name!: HTMLInputElement;

  function updateHop(id: string, patch: Partial<HopForm>) {
    setForm((current) => ({
      ...current,
      target: current.target.id === id ? { ...current.target, ...patch } : current.target,
      jumps: current.jumps.map((jump) => (jump.id === id ? { ...jump, ...patch } : jump)),
    }));
  }

  function moveJump(index: number, by: number) {
    setForm((current) => {
      const jumps = [...current.jumps];
      const [moved] = jumps.splice(index, 1);
      if (moved === undefined) return current;
      jumps.splice(index + by, 0, moved);
      return { ...current, jumps };
    });
  }

  async function loadSavedPasswords() {
    const start = untrack(form);
    for (const hop of [start.target, ...start.jumps]) {
      if (hop.auth === "password") updateHop(hop.id, { hasSavedPassword: (await secrets.password(hop.id)) !== null });
    }
  }

  onSettled(() => {
    if (window.innerWidth >= compactWidthBelow) name.focus();
    void loadSavedPasswords();
  });

  async function fromDraft(pick: () => Promise<MachineDraft | undefined>) {
    const draft = await pick();
    if (draft !== undefined) setForm((current) => formWithDraft(current, draft, newId));
  }

  async function addKey(hopId: string, generate: boolean) {
    const key = generate ? await showGenerateKeyDialog() : await showImportKeyDialog();
    if (key !== undefined) updateHop(hopId, { keyId: key.id });
  }

  async function save() {
    const current = form();
    const found = formErrors(current, keys.keys());
    setErrors(found);
    if (found !== undefined) {
      flush();
      // It may be a hop below the visible part of the form.
      const first =
        found.name !== undefined
          ? "name"
          : [current.target, ...current.jumps].find((hop) => found.hops.has(hop.id))?.id;
      if (first !== undefined) anchors.get(first)?.scrollIntoView({ block: "center", behavior: "smooth" });
      return;
    }
    props.setSaving(true);
    const result = editorSave(current, { createdAt: editing?.createdAt, now: Date.now() });
    try {
      await machines.save(result.machine, { passwords: result.passwords, hostKeys: result.hostKeys });
    } catch (error) {
      props.setSaving(false);
      showSnackBar(errorText(error));
      return;
    }
    if (editing === undefined) shell.select({ kind: "MachineSelection", machineId: result.machine.id });
    props.close();
  }

  /** The fields of the hop `hop` reads; a component made once, whose props follow the form. */
  const hopEditor = (hop: () => HopForm) => (
    <HopEditor
      hop={hop()}
      errors={errors()?.hops.get(hop().id)}
      onChange={(patch) => updateHop(hop().id, patch)}
      onAddKey={(generate) => void addKey(hop().id, generate)}
    />
  );

  return (
    <Dialog
      class="machine-editor"
      actions={
        <>
          <TextButton disabled={props.saving} onClick={() => props.close()}>
            {t.common.cancel}
          </TextButton>
          <FilledButton disabled={props.saving} onClick={() => void save()}>
            {t.common.save}
          </FilledButton>
        </>
      }
    >
      <div class="machine-editor-header">
        <h2 class="machine-editor-title">{editing === undefined ? t.editor.addTitle : t.editor.editTitle}</h2>
        <Show when={form().kind === "ssh" && thisComputerAvailable()}>
          <div class="machine-editor-imports">
            <TextButton icon={Symbols.description} onClick={() => void fromDraft(showSshConfigPicker)}>
              {t.editor.fromSshConfig}
            </TextButton>
            <TextButton icon={Symbols.lan} onClick={() => void fromDraft(showTailscalePicker)}>
              {t.editor.fromTailscale}
            </TextButton>
          </div>
        </Show>
      </div>
      <div class="machine-editor-body">
        <Show when={canChooseKind()}>
          <div class="machine-editor-kind">
            <AppSegmented<MachineKind>
              value={form().kind}
              segments={[
                { value: "local", label: t.machines.thisComputer, icon: Symbols.computer },
                { value: "ssh", label: t.editor.kindSsh, icon: Symbols.dns },
              ]}
              onChanged={(kind) => setForm((current) => ({ ...current, kind }))}
            />
          </div>
        </Show>
        <div ref={(element) => anchors.set("name", element)}>
          <LabeledField label={t.editor.name} error={errors()?.name}>
            <TextField
              value={form().name}
              onInput={(text) => setForm((current) => ({ ...current, name: text }))}
              ref={(element) => (name = element)}
            />
          </LabeledField>
        </div>
        <Show when={form().kind === "ssh"}>
          <div class="machine-editor-target" ref={(element) => anchors.set(untrack(form).target.id, element)}>
            {hopEditor(() => form().target)}
          </div>
          <label class="machine-editor-switch">
            <span>{t.editor.tailscale}</span>
            <Switch
              value={form().tailscale}
              onChanged={(tailscale) => setForm((current) => ({ ...current, tailscale }))}
            />
          </label>
          <Show when={form().ignoredProxyCommand}>
            {(command) => <Note icon={Symbols.warning} text={t.editor.proxyCommandIgnored({ command: command() })} />}
          </Show>
          <Show when={form().hostKeys.length > 0}>
            <Note icon={Symbols.verified_user} text={t.editor.hostKeysPretrusted} />
          </Show>
          <h3 class="machine-editor-jumps-title">{t.editor.jumpHosts}</h3>
          <p class="machine-editor-small">{t.editor.jumpHostsHelp}</p>
          <For each={form().jumps} keyed={(jump) => jump.id}>
            {(jump, index) => (
              <div class="machine-editor-jump" ref={(element) => anchors.set(untrack(jump).id, element)}>
                <div class="machine-editor-jump-header">
                  <span class="machine-editor-jump-title">{t.editor.jumpHostN({ n: index() + 1 })}</span>
                  <IconButton
                    icon={Symbols.arrow_upward}
                    tooltip={t.editor.moveUp}
                    disabled={index() === 0}
                    onClick={() => moveJump(index(), -1)}
                  />
                  <IconButton
                    icon={Symbols.arrow_downward}
                    tooltip={t.editor.moveDown}
                    disabled={index() === form().jumps.length - 1}
                    onClick={() => moveJump(index(), 1)}
                  />
                  <IconButton
                    icon={Symbols.close}
                    tooltip={t.editor.remove}
                    onClick={() => {
                      const id = jump().id;
                      anchors.delete(id);
                      setForm((current) => ({ ...current, jumps: current.jumps.filter((each) => each.id !== id) }));
                    }}
                  />
                </div>
                <div class="machine-editor-jump-body">{hopEditor(jump)}</div>
              </div>
            )}
          </For>
          <div class="machine-editor-start">
            <TextButton
              icon={Symbols.add}
              onClick={() =>
                setForm((current) => ({ ...current, jumps: [...current.jumps, blankHop(newId(), newHopAuth())] }))
              }
            >
              {t.editor.addJumpHost}
            </TextButton>
          </div>
        </Show>
      </div>
    </Dialog>
  );
}

function HopEditor(props: {
  readonly hop: HopForm;
  readonly errors: HopErrors | undefined;
  readonly onChange: (patch: Partial<HopForm>) => void;
  /** Imports (false) or generates (true) a key and selects it for the hop. */
  readonly onAddKey: (generate: boolean) => void;
}) {
  const keys = useKeys();
  const chosen = () => (keys.keys().some((key) => key.id === props.hop.keyId) ? props.hop.keyId : undefined);
  const keyOptions = (): (readonly [string | undefined, string])[] => [
    ...(chosen() === undefined ? [[undefined, t.editor.chooseKey] as const] : []),
    ...keys.keys().map((key) => [key.id, `${key.name} · ${key.type}`] as const),
  ];
  return (
    <div class="machine-editor-hop">
      <div class="machine-editor-address">
        <div class="machine-editor-host">
          <LabeledField label={t.editor.host} error={props.errors?.host}>
            <TextField type="url" value={props.hop.host} onInput={(host) => props.onChange({ host })} />
            <Show when={props.errors?.host === undefined}>
              <span class="machine-editor-helper">{t.editor.hostHelper}</span>
            </Show>
          </LabeledField>
        </div>
        <div class="machine-editor-port">
          <LabeledField label={t.editor.port} error={props.errors?.port}>
            <TextField value={props.hop.port} onInput={(port) => props.onChange({ port })} />
          </LabeledField>
        </div>
      </div>
      <LabeledField label={t.editor.user} error={props.errors?.user}>
        <TextField value={props.hop.user} onInput={(user) => props.onChange({ user })} />
      </LabeledField>
      <LabeledField label={t.editor.auth}>
        <AppSelect<AuthMethod>
          expand
          value={props.hop.auth}
          options={authMethods
            .filter((method) => method !== "agent" || isDesktop() || props.hop.auth === "agent")
            .map((method) => [method, authLabel(method)] as const)}
          onChanged={(auth) => props.onChange({ auth })}
        />
      </LabeledField>
      <Show when={props.hop.auth === "agent"}>
        <Note icon={Symbols.info} text={t.editor.agentHelp} />
      </Show>
      <Show when={props.hop.auth === "key"}>
        <Show when={keys.keys().length > 0} fallback={<p>{t.editor.noKeys}</p>}>
          <LabeledField label={t.editor.key} error={props.errors?.key}>
            <AppSelect<string | undefined>
              expand
              value={chosen()}
              options={keyOptions()}
              onChanged={(keyId) => {
                if (keyId !== undefined) props.onChange({ keyId });
              }}
            />
          </LabeledField>
        </Show>
        <div class="machine-editor-buttons">
          <TonalButton onClick={() => props.onAddKey(false)}>{t.editor.importKey}</TonalButton>
          <TonalButton onClick={() => props.onAddKey(true)}>{t.editor.generateKey}</TonalButton>
        </div>
      </Show>
      <Show when={props.hop.auth === "password"}>
        <LabeledField label={t.editor.password}>
          <TextField type="password" value={props.hop.password} onInput={(password) => props.onChange({ password })} />
          <span class="machine-editor-helper">
            {props.hop.hasSavedPassword ? t.editor.passwordSavedHint : t.editor.passwordAskHint}
          </span>
        </LabeledField>
        <label class="machine-editor-check">
          <Checkbox value={props.hop.savePassword} onChanged={(savePassword) => props.onChange({ savePassword })} />
          <span>{t.editor.savePassword}</span>
        </label>
      </Show>
    </div>
  );
}

function Note(props: { readonly icon: string; readonly text: string }) {
  return (
    <div class="machine-editor-note">
      <Icon icon={props.icon} size={18} class="machine-editor-note-icon" />
      <span class="machine-editor-small">{props.text}</span>
    </div>
  );
}
