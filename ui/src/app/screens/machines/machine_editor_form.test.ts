// The contract of test/screens/machines/machine_editor_test.dart, on the form logic the editor runs.
import { expect, test } from "bun:test";
import type { KnownHostRow, SshKeyRow } from "../../database/tables";
import { t } from "../../i18n/i18n";
import { sshEndpoint, sshMachine } from "../../models/machine";
import {
  blankHop,
  defaultAuth,
  editorSave,
  formErrors,
  formWithDraft,
  type HopForm,
  machineForm,
  type MachineForm,
  parsePort,
} from "./machine_editor_form";

const laptopKey: SshKeyRow = {
  id: "k",
  name: "laptop",
  type: "ssh-ed25519",
  publicKey: "ssh-ed25519 AAAA laptop",
  fingerprint: "SHA256:k",
  createdAt: 0,
};

function hostKey(host: string, port: number): KnownHostRow {
  return { host, port, keyType: "ssh-ed25519", keyBlob: "AAAA", fingerprint: `SHA256:${host}`, addedAt: 0 };
}

function filled(hop: HopForm, fields: Partial<HopForm>): HopForm {
  return { ...hop, ...fields };
}

test("a new machine uses key auth when keys are stored", () => {
  const auth = defaultAuth({ keys: [laptopKey], desktop: true });
  expect(auth).toBe("key");
  expect(machineForm({ id: "m", auth, localFirst: false }).target.auth).toBe("key");
  expect(defaultAuth({ keys: [], desktop: true })).toBe("agent");
  expect(defaultAuth({ keys: [], desktop: false })).toBe("password");
});

test("a new machine is this computer first while the device can drive it and has none", () => {
  expect(machineForm({ id: "m", auth: "agent", localFirst: true }).kind).toBe("local");
  expect(machineForm({ id: "m", auth: "agent", localFirst: false }).kind).toBe("ssh");
});

test("Save checks every hop, also those scrolled out of view", () => {
  const base = machineForm({ id: "m", auth: "agent", localFirst: false });
  const form: MachineForm = {
    ...base,
    name: "box",
    target: filled(base.target, { host: "box.example", user: "me" }),
    jumps: [
      filled(blankHop("j1", "agent"), { host: "relay.example", user: "me" }),
      // The second jump host: no host, no user, a port that is no number.
      filled(blankHop("j2", "agent"), { port: "x" }),
    ],
  };
  const errors = formErrors(form, []);
  expect(errors?.name).toBeUndefined();
  expect(errors?.hops.get("j2")).toEqual({
    host: t.common.required,
    port: "Between 1 and 65535",
    user: t.common.required,
  });
  expect([...(errors?.hops.keys() ?? [])]).toEqual(["j2"]);
});

test("a key hop needs a chosen key while keys are stored", () => {
  const base = machineForm({ id: "m", auth: "key", localFirst: false });
  const form: MachineForm = { ...base, name: "box", target: filled(base.target, { host: "h", user: "u" }) };
  expect(formErrors(form, [])).toBeUndefined();
  expect(formErrors(form, [laptopKey])?.hops.get("m")).toEqual({ key: t.editor.chooseKey });
  expect(formErrors({ ...form, target: filled(form.target, { keyId: "k" }) }, [laptopKey])).toBeUndefined();
});

test("ports are whole numbers from 1 to 65535", () => {
  expect(parsePort(" 22 ")).toBe(22);
  expect(parsePort("65535")).toBe(65535);
  expect(parsePort("0")).toBeUndefined();
  expect(parsePort("65536")).toBeUndefined();
  expect(parsePort("22.5")).toBeUndefined();
  expect(parsePort("")).toBeUndefined();
});

test("Save keeps, forgets or replaces each password hop's saved password", () => {
  const base = machineForm({ id: "m", auth: "password", localFirst: false });
  const form: MachineForm = {
    ...base,
    name: " box ",
    target: filled(base.target, { host: " box.example ", user: "me", password: "secret" }),
    jumps: [
      filled(blankHop("j1", "password"), { host: "relay", user: "me", savePassword: false }),
      filled(blankHop("j2", "password"), { host: "relay2", user: "me" }),
    ],
  };
  const saved = editorSave(form, { now: 5 });
  expect(saved.machine).toEqual(
    sshMachine({
      id: "m",
      name: "box",
      createdAt: 5,
      updatedAt: 5,
      target: sshEndpoint({ id: "m", host: "box.example", user: "me", auth: "password" }),
      jumps: [
        sshEndpoint({ id: "j1", host: "relay", user: "me", auth: "password" }),
        sshEndpoint({ id: "j2", host: "relay2", user: "me", auth: "password" }),
      ],
    }),
  );
  expect([...saved.passwords]).toEqual([
    ["m", "secret"],
    ["j1", undefined],
  ]);
});

test("Tailscale's host keys stay with the host they were listed for", () => {
  const base = machineForm({ id: "m", auth: "none", localFirst: false });
  const draft = formWithDraft(
    base,
    {
      name: "pi",
      target: { host: "pi.tailnet.ts.net", port: 22, user: "me", auth: "none" },
      jumps: [],
      tailscale: true,
      hostKeys: [hostKey("pi.tailnet.ts.net", 22)],
    },
    () => "unused",
  );
  expect(editorSave(draft, { now: 1 }).hostKeys).toEqual([hostKey("pi.tailnet.ts.net", 22)]);
  const edited = { ...draft, target: filled(draft.target, { host: "other.example" }) };
  expect(editorSave(edited, { now: 1 }).hostKeys).toEqual([]);
});

test("a draft keeps the target's id and password fields and gives jumps new ids", () => {
  const base = machineForm({ id: "m", auth: "password", localFirst: false });
  const form: MachineForm = {
    ...base,
    target: filled(base.target, { password: "typed", savePassword: false, hasSavedPassword: true }),
    sshConfigAlias: "old",
    ignoredProxyCommand: "nc %h %p",
  };
  const ids = ["j1", "j2"];
  const next = formWithDraft(
    form,
    {
      name: "work",
      target: { host: "work.example", port: 2222, user: "me", auth: "key", keyId: "k" },
      jumps: [{ host: "relay.example", port: 22, user: "me", auth: "agent" }],
      sshConfigAlias: "work",
      tailscale: false,
      hostKeys: [],
    },
    () => ids.shift() ?? "",
  );
  expect(next.kind).toBe("ssh");
  expect(next.target).toEqual({
    id: "m",
    host: "work.example",
    port: "2222",
    user: "me",
    auth: "key",
    keyId: "k",
    password: "typed",
    savePassword: false,
    hasSavedPassword: true,
  });
  expect(next.jumps.map((jump) => jump.id)).toEqual(["j1"]);
  expect(next.sshConfigAlias).toBe("work");
  expect(next.ignoredProxyCommand).toBeUndefined();
});
