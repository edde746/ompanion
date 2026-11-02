// lib/notifications/local_notifications.dart: the system's notification center, through the shell's notify services
// (docs/contracts/bridge.md, "Shell services"). Desktops post their session notifications through it
// (desktop_notifications.ts), every platform its usage reminders (usage_reminders.ts). The shell brings a desktop
// window to the front on a tap and sends `shell.notificationTap`, which screens/shell/notification_host.tsx opens;
// platform.ts keeps the one that launched the app until the host listens.
import { call } from "../../bridge";
import { asJsonObject, boolean } from "../../core/rpc/json_fields";

/** The data of every usage reminder; a session notification's is its SessionTarget. */
export const usageTapData = { usage: true } as const;

/**
 * The same id for `key` in every launch, so a new notification replaces the one an earlier launch left or scheduled,
 * and one the shells take whatever `key` holds: 32-bit FNV-1a of its UTF-8, in hex.
 */
export function notificationId(key: string): string {
  let hash = 0x811c9dc5;
  for (const byte of new TextEncoder().encode(key)) hash = Math.imul(hash ^ byte, 0x01000193) >>> 0;
  return hash.toString(16).padStart(8, "0");
}

export interface SystemNotification {
  /** A newer notification with the same id replaces it, in this launch and later ones. */
  readonly id: string;
  readonly title: string;
  readonly subtitle?: string;
  readonly body: string;
  /** Apple's platforms group a thread's notifications. */
  readonly threadId?: string;
  /** Comes back with a tap. */
  readonly data?: unknown;
  /** Android's notification channel, which the user can mute in the system settings; the shell's default without. */
  readonly channel?: { readonly id: string; readonly name: string };
}

export async function showNotification(notification: SystemNotification): Promise<void> {
  await call("shell.notify", notification);
}

/** Posted by the OS at `atMs`, even while the app is not running where the platform can (Apple, Android). */
export async function scheduleNotification(notification: SystemNotification, atMs: number): Promise<void> {
  await call("shell.notifySchedule", { ...notification, atMs });
}

/** Removes a shown or scheduled notification. */
export async function cancelNotification(id: string): Promise<void> {
  await call("shell.notifyCancel", { id });
}

/**
 * Asks for permission to notify where the system asks: macOS and iOS once, Android from 13 on. False when the user
 * refused, or turned notifications off for the app.
 */
export async function requestNotificationPermission(): Promise<boolean> {
  const answer = await call<unknown>("shell.notifyPermission", { request: true });
  return boolean(asJsonObject(answer, "shell.notifyPermission"), "granted");
}
