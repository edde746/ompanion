// lib/services/secret_store.dart over the shell's secret storage (`shell.secret*`), under the same keys.
import { call } from "../../bridge";

/** A private key in OpenSSH or PEM form with the passphrase it is kept with, if any (lib/models/machine.dart). */
export interface StoredPrivateKey {
  readonly pem: string;
  readonly passphrase?: string;
}

/** Private keys, key passphrases and passwords. They live only here: never in the store documents, never exported. */
export class SecretStore {
  /** `prefix` goes before every key, as the Dart app's `OMPANION_SECRET_PREFIX` does for side-by-side instances. */
  constructor(private readonly prefix = "") {}

  async privateKey(keyId: string): Promise<StoredPrivateKey | null> {
    const pem = await this.read(this.privateKeyName(keyId));
    if (pem === null) return null;
    const passphrase = await this.read(this.passphraseName(keyId));
    return passphrase === null ? { pem } : { pem, passphrase };
  }

  async savePrivateKey(keyId: string, key: StoredPrivateKey): Promise<void> {
    await this.write(this.privateKeyName(keyId), key.pem);
    if (key.passphrase === undefined) await this.delete(this.passphraseName(keyId));
    else await this.write(this.passphraseName(keyId), key.passphrase);
  }

  async deletePrivateKey(keyId: string): Promise<void> {
    await this.delete(this.privateKeyName(keyId));
    await this.delete(this.passphraseName(keyId));
  }

  /** The saved password of one hop, by `SshEndpoint.id`. */
  password(endpointId: string): Promise<string | null> {
    return this.read(`${this.prefix}password.${endpointId}`);
  }

  savePassword(endpointId: string, password: string): Promise<void> {
    return this.write(`${this.prefix}password.${endpointId}`, password);
  }

  deletePassword(endpointId: string): Promise<void> {
    return this.delete(`${this.prefix}password.${endpointId}`);
  }

  /** The kept passphrase of an identity file from `~/.ssh/config`, by the key's SHA-256 fingerprint. */
  keyFilePassphrase(fingerprint: string): Promise<string | null> {
    return this.read(this.keyFilePassphraseName(fingerprint));
  }

  saveKeyFilePassphrase(fingerprint: string, passphrase: string): Promise<void> {
    return this.write(this.keyFilePassphraseName(fingerprint), passphrase);
  }

  deleteKeyFilePassphrase(fingerprint: string): Promise<void> {
    return this.delete(this.keyFilePassphraseName(fingerprint));
  }

  private privateKeyName(keyId: string): string {
    return `${this.prefix}ssh-key.${keyId}.private`;
  }

  private passphraseName(keyId: string): string {
    return `${this.prefix}ssh-key.${keyId}.passphrase`;
  }

  private keyFilePassphraseName(fingerprint: string): string {
    return `${this.prefix}ssh-key-file.${fingerprint}.passphrase`;
  }

  private async read(key: string): Promise<string | null> {
    const { value } = await call<{ value: string | null }>("shell.secretGet", { key });
    return value;
  }

  private async write(key: string, value: string): Promise<void> {
    await call("shell.secretSet", { key, value });
  }

  private async delete(key: string): Promise<void> {
    await call("shell.secretDelete", { key });
  }
}
