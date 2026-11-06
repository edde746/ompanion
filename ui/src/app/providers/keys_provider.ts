// lib/providers/keys_provider.dart: the SSH keys of this device. Public halves in the `keys` document, private halves
// in secure storage.
import { type Accessor, createSignal, type Setter } from "solid-js";
import {
  generateEd25519Key,
  privateKeyIsEncrypted,
  readPrivateKey,
  type SshPublicKey,
  sshPublicKeyAuthorizedKeysLine,
  sshPublicKeyFingerprint,
} from "../../core/ssh/keys";
import type { AppDatabase } from "../database/app_database";
import type { SshKeyRow } from "../database/tables";
import type { SecretStore, StoredPrivateKey } from "../services/secret_store";
import type { MachinesProvider } from "./machines_provider";
import { newId } from "../utils/ids";
import { LoadGate } from "../utils/load_gate";

/** The key with the same fingerprint is already stored. */
export class DuplicateSshKey extends Error {
  constructor(readonly existing: SshKeyRow) {
    super(`the key is already stored as ${existing.name}`);
    this.name = "DuplicateSshKey";
  }
}

/** SSH keys of this device, oldest first. Reads track. */
export class KeysProvider {
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private list: readonly SshKeyRow[] = [];
  private readonly loading = new LoadGate();

  constructor(
    private readonly db: AppDatabase,
    private readonly secrets: SecretStore,
    private readonly machines: MachinesProvider,
  ) {
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
  }

  /** Reads the stored keys; boot calls it, so the first frame waits for nothing. */
  async load(): Promise<void> {
    try {
      this.list = [...(await this.db.keys.read())].sort((a, b) => a.createdAt - b.createdAt);
    } catch (error) {
      this.failLoad(error);
      throw error;
    }
    this.setChanged((count) => count + 1);
    this.loading.loaded();
  }

  /** Rejects {@link ready} with `error`; boot calls it when it fails before {@link load}. */
  failLoad(error: unknown): void {
    this.loading.failed(error);
  }

  /** Resolves once {@link keys} holds the stored keys; rejects when they cannot be read. */
  get ready(): Promise<void> {
    return this.loading.ready;
  }

  /** Empty until the first read of the document is in; see {@link ready}. */
  keys(): readonly SshKeyRow[] {
    this.changed();
    return this.list;
  }

  byId(id: string | undefined): SshKeyRow | undefined {
    return this.keys().find((key) => key.id === id);
  }

  /**
   * Stores an OpenSSH or PEM private key after checking it opens with `passphrase`.
   *
   * Throws `SshKeyException` for a malformed or unsupported key or a wrong passphrase, and {@link DuplicateSshKey} when
   * the key is already stored.
   */
  async importKey(options: { name: string; pem: string; passphrase?: string }): Promise<SshKeyRow> {
    const publicKey = await readPrivateKey(options.pem, { passphrase: options.passphrase });
    await this.ready;
    const fingerprint = sshPublicKeyFingerprint(publicKey);
    const existing = this.list.find((key) => key.fingerprint === fingerprint);
    if (existing !== undefined) throw new DuplicateSshKey(existing);
    const encrypted = privateKeyIsEncrypted(options.pem);
    return this.store(options.name, publicKey, {
      pem: options.pem,
      ...(encrypted && options.passphrase !== undefined ? { passphrase: options.passphrase } : {}),
    });
  }

  async generateEd25519(options: { name: string }): Promise<SshKeyRow> {
    const generated = await generateEd25519Key({ comment: options.name });
    await this.ready;
    return this.store(options.name, generated.publicKey, { pem: generated.privateKeyPem });
  }

  /** Deletes the key; machines that used it keep key auth with no key selected. */
  async delete(key: SshKeyRow): Promise<void> {
    await this.ready;
    await this.write(this.list.filter((row) => row.id !== key.id));
    await this.machines.forgetKey(key.id);
    await this.secrets.deletePrivateKey(key.id);
  }

  private async store(name: string, publicKey: SshPublicKey, privateKey: StoredPrivateKey): Promise<SshKeyRow> {
    const row: SshKeyRow = {
      id: newId(),
      name,
      type: publicKey.type,
      publicKey: sshPublicKeyAuthorizedKeysLine(publicKey),
      fingerprint: sshPublicKeyFingerprint(publicKey),
      createdAt: Date.now(),
    };
    // Secret first: a row without its private key would look usable and fail at connect time.
    await this.secrets.savePrivateKey(row.id, privateKey);
    await this.write([...this.list, row]);
    return row;
  }

  private async write(rows: readonly SshKeyRow[]): Promise<void> {
    this.list = rows;
    this.setChanged((count) => count + 1);
    await this.db.keys.write(rows);
  }
}
