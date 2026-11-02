// Port of test/services/machine_connector_test.dart, over the memory core (src/test/memory_core.ts).
import "../../test/page_globals";
import { describe, expect, test } from "bun:test";
import { PermanentConnectFailure } from "../../core/session/run_session";
import { parseSshPublicKey, sshPublicKeyFingerprint } from "../../core/ssh/keys";
import type { KeyPassphraseRequest } from "../../core/ssh/ssh_config";
import { useMemoryCore } from "../../test/memory_core";
import { rejection } from "../../test/scripted_channel";
import { fixture } from "../../test/ssh_fixtures";
import { AppDatabase } from "../database/app_database";
import type { AuthMethod } from "../database/tables";
import { MissingCredential, sshEndpoint, sshMachine } from "../models/machine";
import { KnownHostsStore } from "./known_hosts_store";
import { ConnectCancelled, type ConnectPrompts, keptPassphrases, MachineConnector, type PassphraseAnswer } from "./machine_connector";
import { SecretStore } from "./secret_store";

useMemoryCore();

function machine(auth: AuthMethod, keyId?: string) {
  return sshMachine({
    id: "m1",
    name: "box",
    createdAt: Date.UTC(2026, 0, 1),
    updatedAt: Date.UTC(2026, 0, 1),
    target: sshEndpoint({ id: "m1", host: "box.example", user: "me", auth, keyId }),
  });
}

const prompts: ConnectPrompts = {
  password: async () => undefined,
  keyboardInteractive: async () => undefined,
  hostKey: async () => false,
  passphrase: async () => undefined,
};

// A session that reconnects in the background stops on these instead of retrying (and prompting) forever.
describe("failures a retry cannot fix are permanent", () => {
  const connector = new MachineConnector(new SecretStore(), new KnownHostsStore(new AppDatabase()));

  test("the user cancels the password prompt", async () => {
    const error = await rejection(connector.open(machine("password"), prompts));
    expect(error).toBeInstanceOf(ConnectCancelled);
    expect(error).toBeInstanceOf(PermanentConnectFailure);
  });

  test("the hop's key was deleted from this device", async () => {
    const error = await rejection(connector.open(machine("key", "gone"), prompts));
    expect(error).toBeInstanceOf(MissingCredential);
    expect(error).toBeInstanceOf(PermanentConnectFailure);
  });
});

describe("identity file passphrases", () => {
  const key = parseSshPublicKey(fixture("ed25519.pub"));
  const fingerprint = sshPublicKeyFingerprint(key);
  const request = (wrong = false): KeyPassphraseRequest => ({
    hop: "me@box.example",
    path: "~/.ssh/id_ed25519",
    publicKey: key,
    wrong,
  });

  test("a passphrase is kept only when the user asks to, and then used without asking", async () => {
    const secrets = new SecretStore();
    let asked = 0;
    const answering = (remember: boolean) =>
      keptPassphrases(secrets, async (): Promise<PassphraseAnswer> => {
        asked++;
        return { passphrase: "secret", remember };
      });

    expect(await answering(false)(request())).toBe("secret");
    expect(await secrets.keyFilePassphrase(fingerprint)).toBeNull();
    expect(await answering(true)(request())).toBe("secret");
    expect(await answering(true)(request())).toBe("secret");
    expect(asked).toBe(2);
  });

  test("a kept passphrase that no longer decrypts the key is forgotten, and the user is asked", async () => {
    const secrets = new SecretStore();
    await secrets.saveKeyFilePassphrase(fingerprint, "old");
    const asked: boolean[] = [];
    const passphrases = keptPassphrases(secrets, async (request) => {
      asked.push(request.wrong);
      return { passphrase: "new", remember: false };
    });

    expect(await passphrases(request())).toBe("old");
    expect(await passphrases(request(true))).toBe("new");
    expect(asked).toEqual([true]);
    expect(await secrets.keyFilePassphrase(fingerprint)).toBeNull();
  });

  test("dismissing the prompt cancels the connection for good", async () => {
    const error = await rejection(keptPassphrases(new SecretStore(), async () => undefined)(request()));
    expect(error).toBeInstanceOf(ConnectCancelled);
    expect(error).toBeInstanceOf(PermanentConnectFailure);
  });
});
