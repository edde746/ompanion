// The machine editor's form as plain data (lib/screens/machines/machine_editor.dart's `_HopFields` and the state of
// `_MachineEditorState`): what it starts from, its checks, and what Save stores.
import { FormatException } from "../../../core/rpc/json_fields";
import type { AuthMethod, KnownHostRow, MachineKind, SshKeyRow } from "../../database/tables";
import { t } from "../../i18n/i18n";
import { localMachine, type Machine, type SshEndpoint, sshMachine } from "../../models/machine";
import type { EndpointDraft, MachineDraft } from "../../models/machine_draft";

/** Form fields of one hop. The id owns the hop's saved password. */
export interface HopForm {
  readonly id: string;
  readonly host: string;
  /** As typed. */
  readonly port: string;
  readonly user: string;
  readonly auth: AuthMethod;
  readonly keyId?: string;
  readonly password: string;
  readonly savePassword: boolean;
  readonly hasSavedPassword: boolean;
}

export interface MachineForm {
  readonly id: string;
  readonly kind: MachineKind;
  readonly name: string;
  readonly target: HopForm;
  readonly jumps: readonly HopForm[];
  readonly sshConfigAlias?: string;
  readonly tailscale: boolean;
  /** Keys a Tailscale draft brought, trusted on save. */
  readonly hostKeys: readonly KnownHostRow[];
  readonly ignoredProxyCommand?: string;
}

function hop(id: string, fields: EndpointDraft): HopForm {
  return {
    id,
    host: fields.host,
    port: String(fields.port),
    user: fields.user,
    auth: fields.auth,
    ...(fields.keyId === undefined ? {} : { keyId: fields.keyId }),
    password: "",
    savePassword: true,
    hasSavedPassword: false,
  };
}

export function blankHop(id: string, auth: AuthMethod): HopForm {
  return hop(id, { host: "", port: 22, user: "", auth });
}

/** A new hop's authentication: a stored key when there is one, else the ssh-agent on desktops and a password elsewhere. */
export function defaultAuth(options: { keys: readonly SshKeyRow[]; desktop: boolean }): AuthMethod {
  if (options.keys.length > 0) return "key";
  return options.desktop ? "agent" : "password";
}

/**
 * The form for `machine`, or for a new machine with id `id`: "This computer" while the device can drive it and has
 * none yet (`localFirst`), else SSH.
 */
export function machineForm(options: {
  machine?: Machine;
  id: string;
  auth: AuthMethod;
  localFirst: boolean;
}): MachineForm {
  const machine = options.machine;
  if (machine?.kind === "SshMachine") {
    return {
      id: machine.id,
      kind: "ssh",
      name: machine.name,
      target: hop(machine.target.id, machine.target),
      jumps: machine.jumps.map((jump) => hop(jump.id, jump)),
      ...(machine.sshConfigAlias === undefined ? {} : { sshConfigAlias: machine.sshConfigAlias }),
      tailscale: machine.tailscale,
      hostKeys: [],
    };
  }
  const id = machine?.id ?? options.id;
  return {
    id,
    kind: machine?.kind === "LocalMachine" || (machine === undefined && options.localFirst) ? "local" : "ssh",
    name: machine?.name ?? "",
    target: blankHop(id, options.auth),
    jumps: [],
    tailscale: false,
    hostKeys: [],
  };
}

/**
 * `form` filled from an SSH config or Tailscale draft. The target keeps its id and password fields, each jump gets an
 * id from `newId`.
 */
export function formWithDraft(form: MachineForm, draft: MachineDraft, newId: () => string): MachineForm {
  const { password, savePassword, hasSavedPassword } = form.target;
  return {
    id: form.id,
    kind: "ssh",
    name: draft.name,
    target: { ...hop(form.target.id, draft.target), password, savePassword, hasSavedPassword },
    jumps: draft.jumps.map((jump) => hop(newId(), jump)),
    ...(draft.sshConfigAlias === undefined ? {} : { sshConfigAlias: draft.sshConfigAlias }),
    tailscale: draft.tailscale,
    hostKeys: draft.hostKeys,
    ...(draft.ignoredProxyCommand === undefined ? {} : { ignoredProxyCommand: draft.ignoredProxyCommand }),
  };
}

/** The port `text` names, 1 to 65535, or undefined. */
export function parsePort(text: string): number | undefined {
  const trimmed = text.trim();
  if (!/^[+-]?\d+$/.test(trimmed)) return undefined;
  const port = Number(trimmed);
  return port >= 1 && port <= 65535 ? port : undefined;
}

export interface HopErrors {
  readonly host?: string;
  readonly port?: string;
  readonly user?: string;
  readonly key?: string;
}

export interface FormErrors {
  readonly name?: string;
  /** By hop id; only hops with an error. */
  readonly hops: ReadonlyMap<string, HopErrors>;
}

function required(value: string): string | undefined {
  return value.trim() === "" ? t.common.required : undefined;
}

/** What is wrong with `hop`; the key is checked only while there are keys to choose from, as the editor offers them. */
export function hopErrors(hop: HopForm, keys: readonly SshKeyRow[]): HopErrors {
  const errors = {
    host: required(hop.host),
    port: parsePort(hop.port) === undefined ? t.editor.invalidPort : undefined,
    user: required(hop.user),
    key:
      hop.auth === "key" && keys.length > 0 && !keys.some((key) => key.id === hop.keyId) ? t.editor.chooseKey : undefined,
  };
  return Object.fromEntries(Object.entries(errors).filter(([, error]) => error !== undefined));
}

/** Every field's error, every hop's included; undefined when the form can be saved. */
export function formErrors(form: MachineForm, keys: readonly SshKeyRow[]): FormErrors | undefined {
  const name = required(form.name);
  const hops = new Map<string, HopErrors>();
  if (form.kind === "ssh") {
    for (const each of [form.target, ...form.jumps]) {
      const errors = hopErrors(each, keys);
      if (Object.keys(errors).length > 0) hops.set(each.id, errors);
    }
  }
  if (name === undefined && hops.size === 0) return undefined;
  return { ...(name === undefined ? {} : { name }), hops };
}

/** What Save hands `MachinesProvider.save`. */
export interface EditorSave {
  readonly machine: Machine;
  /** A password to save, or undefined to forget the saved one, by hop id. */
  readonly passwords: ReadonlyMap<string, string | undefined>;
  readonly hostKeys: readonly KnownHostRow[];
}

function endpoint(hop: HopForm): SshEndpoint {
  const port = parsePort(hop.port);
  if (port === undefined) throw new FormatException(`not a port: ${hop.port}`);
  return {
    id: hop.id,
    host: hop.host.trim(),
    port,
    user: hop.user.trim(),
    auth: hop.auth,
    ...(hop.auth === "key" && hop.keyId !== undefined ? { keyId: hop.keyId } : {}),
  };
}

/** The machine a form without {@link formErrors} saves; `createdAt` is the edited machine's. */
export function editorSave(form: MachineForm, options: { createdAt?: number; now: number }): EditorSave {
  const times = { createdAt: options.createdAt ?? options.now, updatedAt: options.now };
  const name = form.name.trim();
  if (form.kind === "local") {
    return { machine: localMachine({ id: form.id, name, ...times }), passwords: new Map(), hostKeys: [] };
  }
  const target = endpoint(form.target);
  const passwords = new Map<string, string | undefined>();
  for (const each of [form.target, ...form.jumps]) {
    if (each.auth !== "password") continue;
    if (!each.savePassword) passwords.set(each.id, undefined);
    else if (each.password !== "") passwords.set(each.id, each.password);
  }
  return {
    machine: sshMachine({
      id: form.id,
      name,
      ...times,
      target,
      jumps: form.jumps.map(endpoint),
      ...(form.sshConfigAlias === undefined ? {} : { sshConfigAlias: form.sshConfigAlias }),
      tailscale: form.tailscale,
    }),
    passwords,
    // Keys from Tailscale belong to the host they were listed for; an edited host does not inherit them.
    hostKeys: form.hostKeys.filter((row) => row.host === target.host && row.port === target.port),
  };
}
