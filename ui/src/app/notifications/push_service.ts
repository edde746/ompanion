// Port of lib/notifications/push_service.dart. Its `ompanion/push` method channel is the shell's `shell.push*` methods
// (docs/contracts/bridge.md, "Shell services"); the channel's `fid` and `tap` calls arrive as the `shell.pushFid` and
// `shell.pushTap` events, which platform.ts subscribes to as it loads (`pushFids`, `pushTaps`). The app lifecycle the
// Dart observes is `appActive` (`shell.appState`).
import { type Accessor, createEffect, createRoot, createSignal, type Setter } from "solid-js";
import { call } from "../../bridge";
import {
  type NotificationKind,
  notificationKinds,
  type PushPlatform,
  pushRegistration,
  removePushRegistration,
  writePushRegistration,
} from "../../core/host/push_registration";
import { asJsonObject, boolean, enumByName, optString, string } from "../../core/rpc/json_fields";
import type { MachineRuntime } from "../../core/session/machine_runtime";
import { Emitter, type EventStream, type Subscription } from "../../core/util/stream";
import type { Machine } from "../models/machine";
import { appActive, pushFids, pushTaps } from "../platform";
import type { MachinesProvider } from "../providers/machines_provider";
import { Prefs, type SettingsProvider } from "../providers/settings_provider";
import type { ShellProvider } from "../providers/shell_provider";
import type { SessionsProvider } from "../sessions/sessions_provider";
import { type SessionTarget, sessionTargetFromJson } from "../sessions/show_session";
import { appLogger } from "../utils/app_logger";

/** Whether this build can receive push notifications, and why not. */
export interface PushAvailability {
  readonly available: boolean;
  readonly reason: string | undefined;
}

/** A registration write or removal that failed, with its machine. */
export interface PushFailure {
  readonly machine: Machine;
  readonly error: unknown;
}

interface Registration {
  readonly platform: PushPlatform;
  readonly fid: string;
  readonly key: string;
}

const pushPlatforms: readonly PushPlatform[] = ["android", "ios"];

/**
 * Phone push (docs/contracts/push.md) on Android and iOS: the shell's native FCM code behind `shell.push*`, this
 * phone's registration file on the machines, and the session the phone shows, whose messages native code keeps out of
 * the notification shade.
 *
 * While push is on, every machine gets the registration each time it connects, and the connected ones again when its
 * Firebase installation ID (FID) or the wanted kinds change. Turning push off removes it from the connected machines
 * and from the others on their next connect (`Prefs.pushRemovals`). A failed write or removal lands on
 * {@link failures}.
 *
 * Reading {@link enabled}, {@link availability}, {@link busy}, {@link lostKey} or {@link isOnline} in a tracking scope
 * follows every change.
 */
export class PushService {
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private readonly failuresEmitter = new Emitter<PushFailure>();
  /** Each machine's runtime and the subscription to its status; a route change replaces the runtime. */
  private readonly statuses = new Map<string, { runtime: MachineRuntime; subscription: Subscription }>();
  /** The registration writes and removals of each machine, one after the other. */
  private readonly queues = new Map<string, Promise<void>>();
  private kinds: ReadonlySet<NotificationKind>;
  private registration: Registration | undefined;
  private answeredAvailability: PushAvailability | undefined;
  private visible: SessionTarget | undefined;
  private isBusy = false;
  private keyLost = false;
  private disposed = false;
  private unfollow: (() => void) | undefined;

  private constructor(
    private readonly sessions: SessionsProvider,
    private readonly machines: MachinesProvider,
    private readonly settings: SettingsProvider,
  ) {
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
    this.kinds = new Set(notificationKinds.filter((kind) => settings.get(Prefs.notify(kind))));
  }

  /**
   * Follows the machines' connections, the wanted kinds, the new FIDs and the session on screen, and takes native
   * code's registration while push is on.
   */
  static following(options: {
    sessions: SessionsProvider;
    shell: ShellProvider;
    machines: MachinesProvider;
    settings: SettingsProvider;
  }): PushService {
    const { sessions, shell, machines, settings } = options;
    const push = new PushService(sessions, machines, settings);
    const subscriptions = [
      pushFids.listen((fid) => {
        push.onFid(fid).catch((error: unknown) => appLogger.w("push: taking the new FID failed", { error }));
      }),
      sessions.changes.listen(() => push.follow()),
      machines.changes.listen(() => push.follow()),
    ];
    // The kinds and the shell's selection are signals: effects follow them.
    const disposeRoot = createRoot((dispose) => {
      createEffect(
        () => new Set(notificationKinds.filter((kind) => settings.get(Prefs.notify(kind)))),
        (kinds) => push.onKinds(kinds),
      );
      createEffect(
        (): SessionTarget | undefined => {
          const shown = appActive() && shell.selection().kind === "SessionSelection";
          const session = shown ? sessions.active() : undefined;
          const machine = session === undefined ? undefined : sessions.machineOf(session);
          if (session === undefined || machine === undefined) return undefined;
          return { machineId: machine.id, runId: session.runId, sessionPath: session.sessionPath };
        },
        (visible) => push.syncVisible(visible),
      );
      return dispose;
    });
    push.unfollow = () => {
      for (const subscription of subscriptions) subscription.cancel();
      disposeRoot();
    };
    push.follow();
    push.start().catch((error: unknown) => appLogger.w("push: reading this phone's registration failed", { error }));
    return push;
  }

  /** Push is on for this phone. */
  enabled(): boolean {
    return this.settings.get(Prefs.pushNotifications);
  }

  /** Undefined until {@link checkAvailability} answered. */
  availability(): PushAvailability | undefined {
    this.changed();
    return this.answeredAvailability;
  }

  /** Push is being turned on or off. */
  busy(): boolean {
    this.changed();
    return this.isBusy;
  }

  /**
   * Push was on, but native code had no key any more: a restore from a backup brings the setting and not the key, which
   * stays on the phone it was made on. Push was turned off then, and the machines' registrations, which name that key,
   * go on their next connect.
   */
  lostKey(): boolean {
    this.changed();
    return this.keyLost;
  }

  /** Taps on notifications while the app runs. One listener. */
  get taps(): EventStream<SessionTarget> {
    return pushTaps;
  }

  /** Registration writes and removals that failed, with their machine. */
  get failures(): EventStream<PushFailure> {
    return this.failuresEmitter.stream;
  }

  /** The tap on a notification that launched the app, once. Native code holds taps until this is first called. */
  async takeLaunchTap(): Promise<SessionTarget | undefined> {
    const tap = await call<unknown>("shell.pushTakeLaunchTap");
    return tap === null ? undefined : sessionTargetFromJson(tap);
  }

  async checkAvailability(): Promise<void> {
    const status = asJsonObject(await call<unknown>("shell.pushStatus"), "shell.pushStatus");
    this.answeredAvailability = { available: boolean(status, "available"), reason: optString(status, "reason") };
    this.notify();
  }

  /**
   * Asks for permission, makes the key and registers the installation for messaging natively, then writes the
   * registration to the connected machines. Throws a `BridgeError` with code `denied`, `unavailable` or `failed`.
   */
  enable(): Promise<void> {
    return this.whileBusy(async () => {
      this.registration = registrationFromJson(
        await call<unknown>("shell.pushEnable", { deviceId: this.sessions.deviceId }),
      );
      this.keyLost = false;
      await this.settings.set(Prefs.pushRemovals, []);
      await this.settings.set(Prefs.pushNotifications, true);
      this.syncOnline();
    });
  }

  /** Unregisters and deletes the installation and the key natively, then removes the registration from the machines. */
  disable(): Promise<void> {
    return this.whileBusy(async () => {
      await call("shell.pushDisable");
      this.registration = undefined;
      await this.settings.set(
        Prefs.pushRemovals,
        this.machines.machines().map((machine) => machine.id),
      );
      await this.settings.set(Prefs.pushNotifications, false);
      this.syncOnline();
    });
  }

  /**
   * The companion's `notify.test` on `machine`, once its registration is written. Throws a `CompanionException`
   * `not_found` without a registration there, `failed` when the relay refused.
   */
  async sendTest(machine: Machine): Promise<void> {
    await this.queues.get(machine.id);
    const control = await this.sessions.control(machine);
    await control.companion.call("notify.test");
  }

  /** Whether `machine` is connected, so {@link sendTest} can reach it. */
  isOnline(machine: Machine): boolean {
    this.changed();
    return this.sessions.runtimeFor(machine).status.kind === "MachineOnline";
  }

  dispose(): void {
    this.disposed = true;
    this.unfollow?.();
    for (const { subscription } of this.statuses.values()) subscription.cancel();
    this.failuresEmitter.close();
  }

  private async start(): Promise<void> {
    if (this.enabled()) await this.adopt(await call<unknown>("shell.pushRegistration"));
  }

  /** Takes native code's registration while push is on; none means the key is gone ({@link lostKey}). */
  private async adopt(json: unknown): Promise<void> {
    const registration = registrationFromJson(json);
    if (registration === undefined) {
      this.keyLost = true;
      await this.settings.set(
        Prefs.pushRemovals,
        this.machines.machines().map((machine) => machine.id),
      );
      await this.settings.set(Prefs.pushNotifications, false);
      this.notify();
    } else {
      this.registration = registration;
    }
    this.syncOnline();
  }

  private async onFid(fid: string): Promise<void> {
    if (!this.enabled()) return;
    const registration = this.registration;
    if (registration === undefined) return this.adopt(await call<unknown>("shell.pushRegistration"));
    this.registration = { ...registration, fid };
    this.syncOnline();
  }

  private onKinds(kinds: ReadonlySet<NotificationKind>): void {
    if (kinds.size === this.kinds.size && [...kinds].every((kind) => this.kinds.has(kind))) return;
    this.kinds = kinds;
    if (this.enabled()) this.syncOnline();
  }

  /** Subscribes to every machine's runtime status: a machine that comes online gets its registration. */
  private follow(): void {
    const ids = new Set<string>();
    for (const machine of this.machines.machines()) {
      const id = machine.id;
      ids.add(id);
      const runtime = this.sessions.runtimeFor(machine);
      const current = this.statuses.get(id);
      if (current?.runtime === runtime) continue;
      current?.subscription.cancel();
      this.statuses.set(id, {
        runtime,
        subscription: runtime.statuses.listen((status) => {
          // isOnline follows the status.
          this.notify();
          if (status.kind === "MachineOnline") this.sync(id);
        }),
      });
      if (runtime.status.kind === "MachineOnline") this.sync(id);
    }
    for (const [id, entry] of this.statuses) {
      if (ids.has(id)) continue;
      entry.subscription.cancel();
      this.statuses.delete(id);
    }
  }

  private syncOnline(): void {
    for (const machine of this.machines.machines()) {
      if (this.isOnline(machine)) this.sync(machine.id);
    }
  }

  private sync(machineId: string): void {
    const queue = (this.queues.get(machineId) ?? Promise.resolve())
      .then(() => this.apply(machineId))
      .catch((error: unknown) => {
        const machine = this.machines.byId(machineId);
        if (machine !== undefined && !this.failuresEmitter.closed) this.failuresEmitter.add({ machine, error });
      });
    this.queues.set(machineId, queue);
  }

  /**
   * Writes or removes `machineId`'s registration as push stands now; a machine that went offline meanwhile gets it on
   * its next connect.
   */
  private async apply(machineId: string): Promise<void> {
    const machine = this.machines.byId(machineId);
    if (machine === undefined || this.disposed) return;
    const runtime = this.sessions.runtimeFor(machine);
    if (runtime.status.kind !== "MachineOnline") return;
    const registration = this.registration;
    if (this.enabled()) {
      if (registration === undefined) return;
      await writePushRegistration(
        runtime.link,
        pushRegistration({
          deviceId: this.sessions.deviceId,
          machineId: machine.id,
          machineName: machine.name,
          platform: registration.platform,
          fid: registration.fid,
          key: registration.key,
          kinds: this.kinds,
        }),
      );
    } else if (this.settings.get(Prefs.pushRemovals).includes(machineId)) {
      await removePushRegistration(runtime.link, this.sessions.deviceId);
      await this.settings.set(
        Prefs.pushRemovals,
        this.settings.get(Prefs.pushRemovals).filter((id) => id !== machineId),
      );
    }
  }

  /**
   * Tells native code which session the phone shows while in the foreground, and clears that session's
   * notifications: it is being read.
   */
  private syncVisible(visible: SessionTarget | undefined): void {
    const before = this.visible;
    const same =
      visible?.machineId === before?.machineId &&
      visible?.runId === before?.runId &&
      visible?.sessionPath === before?.sessionPath;
    if (same) return;
    this.visible = visible;
    // No machine id: no session is visible.
    call("shell.pushSetVisible", visible ?? {}).catch((error: unknown) =>
      appLogger.w("push: telling the shell the visible session failed", { error }),
    );
    if (visible === undefined) return;
    call("shell.pushClear", { machineId: visible.machineId, runId: visible.runId }).catch((error: unknown) =>
      appLogger.w(`push: clearing the notifications of ${visible.runId} failed`, { error }),
    );
  }

  private async whileBusy(body: () => Promise<void>): Promise<void> {
    this.isBusy = true;
    this.notify();
    try {
      await body();
    } finally {
      this.isBusy = false;
      this.notify();
    }
  }

  private notify(): void {
    if (!this.disposed) this.setChanged((count) => count + 1);
  }
}

/** The `shell.pushEnable` and `shell.pushRegistration` answer; undefined when native code has none. */
function registrationFromJson(json: unknown): Registration | undefined {
  if (json === null) return undefined;
  const fields = asJsonObject(json, "push registration");
  return {
    platform: enumByName(pushPlatforms, string(fields, "platform")),
    fid: string(fields, "fid"),
    key: string(fields, "key"),
  };
}
