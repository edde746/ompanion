import { mkdir, writeFile } from "node:fs/promises";
import { join } from "node:path";

import { config } from "../config.js";

/** Writes an object under its digest and returns the key it can be read back by. */
export async function putObject(digest: string, body: Uint8Array): Promise<string> {
  const prefix = digest.slice(0, 2);
  const key = `${prefix}/${digest}`;
  await mkdir(join(config.storageDir, prefix), { recursive: true });
  await writeFile(join(config.storageDir, key), body);
  return key;
}
