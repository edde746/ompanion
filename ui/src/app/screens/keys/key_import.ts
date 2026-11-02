// What importing an SSH key decides (lib/screens/keys/key_dialogs.dart), apart from its dialogs: whether a picked file
// holds key text, and the line an import failure shows.
import { SshKeyException } from "../../../core/ssh/keys";
import { t } from "../../i18n/i18n";
import { DuplicateSshKey } from "../../providers/keys_provider";

/** OpenSSH private keys are a few KiB; anything much larger is the wrong file. */
export const maxKeyFileBytes = 64 * 1024;

/** Why a key could not be imported: a key the app cannot read or open, or one already stored. */
export function describeKeyError(error: unknown): string {
  if (error instanceof SshKeyException) {
    switch (error.problem) {
      case "malformed":
        return t.keys.malformed;
      case "unsupported":
        return t.keys.unsupported;
      case "passphraseRequired":
        return t.keys.passphraseRequired;
      case "wrongPassphrase":
        return t.keys.wrongPassphrase;
    }
  }
  if (error instanceof DuplicateSshKey) return t.keys.duplicate({ name: error.existing.name });
  return String(error);
}

/** The text of a picked key file, or why it cannot be a key: too large, or not UTF-8 text. */
export async function readKeyFile(file: Blob): Promise<{ text: string } | { error: string }> {
  if (file.size > maxKeyFileBytes) return { error: t.keys.fileTooLarge };
  return keyFileText(new Uint8Array(await file.arrayBuffer()));
}

/** The text a key file's `bytes` hold, or why they cannot be a key: more than a key file holds, or not UTF-8 text. */
export function keyFileText(bytes: Uint8Array): { text: string } | { error: string } {
  if (bytes.length > maxKeyFileBytes) return { error: t.keys.fileTooLarge };
  try {
    return { text: new TextDecoder("utf-8", { fatal: true }).decode(bytes) };
  } catch (error) {
    // A fatal decoder throws TypeError for bytes that are not UTF-8.
    if (!(error instanceof TypeError)) throw error;
    return { error: t.keys.malformed };
  }
}
