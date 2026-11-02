// Port of packages/omp_core/lib/src/host/keep_awake.dart.
import type { HostLink } from "../transport/host_link";
import { appDirName, ensureAppDir } from "./scripts";

/**
 * `~/.ompanion/keep-awake`: while it exists, the companion in each of the machine's runs holds a Mac awake while omp
 * works (docs/contracts/host-launch.md, "Keep awake"). One switch per machine, shared by every device.
 */
const keepAwakeName = "keep-awake";

/** Whether the machine's keep-awake file exists. */
export async function keepAwake(link: HostLink): Promise<boolean> {
  const files = await link.files();
  try {
    return (await files.stat(`${await files.home()}/${appDirName}/${keepAwakeName}`, { followLinks: false })) !== null;
  } finally {
    await files.close();
  }
}

/**
 * Creates the machine's keep-awake file, or removes it; one already in the asked state is left alone. Runs read it
 * when omp starts to work and, while they hold the machine awake, every few seconds.
 */
export async function setKeepAwake(link: HostLink, on: boolean): Promise<void> {
  const files = await link.files();
  try {
    const dir = await ensureAppDir(files, "");
    const path = `${dir}/${keepAwakeName}`;
    const exists = (await files.stat(path, { followLinks: false })) !== null;
    if (on && !exists) await files.write(path, new Uint8Array(0), { mode: 0o600 });
    if (!on && exists) await files.remove(path);
  } finally {
    await files.close();
  }
}
