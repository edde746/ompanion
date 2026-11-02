// Port of packages/omp_core/lib/src/host/companion.dart.
import { followScript } from "../channel/follow";
import { logScript } from "../channel/log_script";
import type { HostLink } from "../transport/host_link";
import { sha256Hex } from "../util/sha256";
import { ensureAppDir, hostPath, newMarker } from "./scripts";

/**
 * Puts the companion extension at `~/.ompanion/companion/<ompVersion>/<sha256>.js`, and [logScript] and [followScript]
 * next to it at `log.<sha256>.js` and `follow.<sha256>.js`, and returns their host-native paths: the companion's is
 * the value for omp's `-e`. The directory sits outside omp's extension discovery roots, so the user's TUI never loads
 * any of them. A file already there with the same content is left alone; a partial or corrupt one is replaced.
 * Uploads go to a temporary name first, so a final path only ever holds a complete file.
 */
export async function uploadCompanion(
  link: HostLink,
  options: { ompVersion: string; bytes: Uint8Array },
): Promise<{ companion: string; log: string; follow: string }> {
  const { ompVersion } = options;
  if (!/^[0-9A-Za-z.+-]+$/.test(ompVersion)) {
    throw new RangeError(`Invalid argument (ompVersion): not a version: ${JSON.stringify(ompVersion)}`);
  }
  const files = await link.files();
  try {
    const dir = await ensureAppDir(files, `companion/${ompVersion}`);
    const put = async (prefix: string, content: Uint8Array): Promise<string> => {
      const digest = sha256Hex(content);
      const path = `${dir}/${prefix}${digest}.js`;
      const existing = await files.stat(path);
      if (existing !== null && existing.size === content.length) {
        if (sha256Hex(await files.read(path)) === digest) return hostPath(path);
      }
      const temp = `${dir}/${prefix}${digest}.${newMarker()}.part`;
      await files.write(temp, content, { mode: 0o600 });
      if (existing !== null) await files.remove(path);
      await files.rename(temp, path);
      return hostPath(path);
    };
    const encoder = new TextEncoder();
    return {
      companion: await put("", options.bytes),
      log: await put("log.", encoder.encode(logScript)),
      follow: await put("follow.", encoder.encode(followScript)),
    };
  } finally {
    await files.close();
  }
}
