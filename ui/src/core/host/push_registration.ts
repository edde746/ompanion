// Port of packages/omp_core/lib/src/host/push_registration.dart.
import type { HostFiles, HostLink } from "../transport/host_link";
import { appDirName, ensureAppDir, newMarker } from "./scripts";

/** Where a machine's companion posts phone notifications (docs/contracts/push.md, "Relay"). */
export const pushRelayUrl = "https://push.ompanion.app/v1/send";

/** What a notification is about, in the contract's order. The companion also sends `test`, which no registration lists. */
export const notificationKinds = ["input", "done", "failed"] as const;
export type NotificationKind = (typeof notificationKinds)[number];

export type PushPlatform = "android" | "ios";

/**
 * A phone's registration file on one machine, `<home>/.ompanion/push/<deviceId>.json` (docs/contracts/push.md,
 * "Registration file"). Made by [pushRegistration], which checks the device id.
 */
export interface PushRegistration {
  /** The app's device id, which names the file. */
  readonly deviceId: string;
  readonly machineId: string;
  readonly machineName: string;
  readonly platform: PushPlatform;
  /** The phone's Firebase installation ID, registered for messaging. */
  readonly fid: string;
  /** Base64 of the 32-byte AES-256-GCM key. */
  readonly key: string;
  readonly kinds: ReadonlySet<NotificationKind>;
}

const deviceIdPattern = /^[0-9a-f]{32}$/;

function checkDeviceId(deviceId: string): void {
  if (!deviceIdPattern.test(deviceId)) {
    throw new RangeError(`Invalid argument (deviceId): not 32 lowercase hex: ${JSON.stringify(deviceId)}`);
  }
}

/** A registration whose device id is 32 lowercase hex, so it can name a file. */
export function pushRegistration(fields: PushRegistration): PushRegistration {
  checkDeviceId(fields.deviceId);
  return fields;
}

/**
 * The file's bytes: the contract's fields in the contract's order, so an unchanged registration encodes to the same
 * bytes and is not written again.
 */
export function pushRegistrationEncode(registration: PushRegistration): Uint8Array {
  const json = {
    v: 1,
    deviceId: registration.deviceId,
    machineId: registration.machineId,
    machineName: registration.machineName,
    platform: registration.platform,
    fid: registration.fid,
    key: registration.key,
    kinds: notificationKinds.filter((kind) => registration.kinds.has(kind)),
    relay: pushRelayUrl,
  };
  return new TextEncoder().encode(`${JSON.stringify(json)}\n`);
}

/**
 * Puts [registration] on the machine: mode 0600 in a 0700 directory, through a temporary name so the companion never
 * reads half a file. A file with the same bytes is left alone. The temporary file holds the key, so a failed write
 * removes it; one a lost link leaves behind goes with [removePushRegistration].
 */
export async function writePushRegistration(link: HostLink, registration: PushRegistration): Promise<void> {
  const bytes = pushRegistrationEncode(registration);
  const files = await link.files();
  try {
    const dir = await ensureAppDir(files, pushDir);
    const path = `${dir}/${registration.deviceId}.json`;
    const existing = await files.stat(path, { followLinks: false });
    if (existing !== null && existing.size === bytes.length && equal(await files.read(path), bytes)) return;
    // Not `.json`: the companion reads every `push/*.json`.
    const temp = `${dir}/${registration.deviceId}.${newMarker()}.part`;
    try {
      await files.write(temp, bytes, { mode: 0o600 });
      await replace(files, temp, path);
    } catch (error) {
      await removeIfPresent(files, temp);
      throw error;
    }
  } finally {
    await files.close();
  }
}

/**
 * Deletes the registration of [deviceId] from the machine, and temporary files an interrupted write left; none there
 * is not an error.
 */
export async function removePushRegistration(link: HostLink, deviceId: string): Promise<void> {
  checkDeviceId(deviceId);
  const files = await link.files();
  try {
    const dir = `${await files.home()}/${appDirName}/${pushDir}`;
    if ((await files.stat(dir)) === null) return;
    for (const { name } of await files.list(dir)) {
      if (name === `${deviceId}.json` || (name.startsWith(`${deviceId}.`) && name.endsWith(".part"))) {
        await removeIfPresent(files, `${dir}/${name}`);
      }
    }
  } finally {
    await files.close();
  }
}

/**
 * Moves [temp] over [path]. SFTP's `posix-rename@openssh.com` replaces [path] atomically when the server offers it, and
 * a local rename replaces too; plain SFTP rename refuses an existing target, which is then removed first. The
 * companion may delete [path] at any moment (a `410` from the relay).
 */
async function replace(files: HostFiles, temp: string, path: string): Promise<void> {
  try {
    await files.rename(temp, path);
    return;
  } catch (error) {
    if ((await files.stat(path, { followLinks: false })) === null) throw error;
  }
  await removeIfPresent(files, path);
  await files.rename(temp, path);
}

/** Removes [path]; one that is gone already is fine. */
async function removeIfPresent(files: HostFiles, path: string): Promise<void> {
  try {
    await files.remove(path);
  } catch (error) {
    if ((await files.stat(path, { followLinks: false })) !== null) throw error;
  }
}

const pushDir = "push";

function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}
