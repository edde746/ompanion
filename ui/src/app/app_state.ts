// What lib/app/app.dart's MultiProvider hands down: the app creates one of each at boot and passes them through Solid
// contexts; a component reads them with the use…() hooks, as `context.read<T>()` / `context.watch<T>()` do.
import { type Accessor, createContext, createSignal, useContext } from "solid-js";
import { AppDatabase } from "./database/app_database";
import type { PushService } from "./notifications/push_service";
import type { UsageReminders } from "./notifications/usage_reminders";
import { appResumes, isDesktop, shellInfo } from "./platform";
import { KeysProvider } from "./providers/keys_provider";
import { MachinesProvider } from "./providers/machines_provider";
import { Prefs, SettingsProvider } from "./providers/settings_provider";
import { ShellProvider } from "./providers/shell_provider";
import { DockController } from "./screens/dock/dock_controller";
import { KnownHostsStore } from "./services/known_hosts_store";
import { MachineConnector } from "./services/machine_connector";
import { SecretStore } from "./services/secret_store";
import { bundledCompanion } from "./sessions/companion_asset";
import { MachineImages, machineImageCacheDir } from "./sessions/machine_images";
import { SessionPins } from "./sessions/session_pins";
import { SessionReads } from "./sessions/session_reads";
import { SessionsProvider } from "./sessions/sessions_provider";

export interface AppState {
  readonly db: AppDatabase;
  readonly settings: SettingsProvider;
  readonly secrets: SecretStore;
  readonly shell: ShellProvider;
  readonly knownHosts: KnownHostsStore;
  readonly keys: KeysProvider;
  readonly images: MachineImages;
  readonly machines: MachinesProvider;
  readonly connector: MachineConnector;
  readonly sessions: SessionsProvider;
  readonly sessionReads: SessionReads;
  readonly sessionPins: SessionPins;
  readonly dock: DockController;
  /** The usage pane's reminders; undefined until {@link startNotifications} started them. */
  readonly usageReminders: Accessor<UsageReminders | undefined>;
  /**
   * Phone push; undefined until {@link startNotifications} started it, and on a build that cannot receive push (the
   * Flutter app made it on Android and iOS).
   */
  readonly push: Accessor<PushService | undefined>;
  /**
   * Starts the notifications (desktops: the sessions open here; every device: the usage reminders; phones: push) once
   * `bootApp` loaded the settings and machines they read. Their code loads only then, off the first frame.
   */
  startNotifications(): Promise<void>;
}

/**
 * The providers, created once per page; `settings` starts from the last run's snapshot. None reads its document
 * here: `bootApp` loads them after the first frame.
 */
export function createAppState(): AppState {
  const db = new AppDatabase();
  const settings = new SettingsProvider(db);
  const secrets = new SecretStore();
  const shell = new ShellProvider();
  const knownHosts = new KnownHostsStore(db);
  const images = new MachineImages({ cacheDir: machineImageCacheDir });
  const machines = new MachinesProvider(db, secrets, knownHosts, settings, images);
  const keys = new KeysProvider(db, secrets, machines);
  const connector = new MachineConnector(secrets, knownHosts, {
    // The first connect may come before the keys are read.
    keyName: async (keyId) => {
      await keys.ready;
      return keys.byId(keyId)?.name;
    },
  });
  const sessions = new SessionsProvider({
    connector,
    machines,
    deviceId: () => settings.get(Prefs.deviceId),
    companionBytes: bundledCompanion,
  });
  // For the page's life, as the providers.
  appResumes.listen(() => sessions.checkLinks());
  const [usageReminders, setUsageReminders] = createSignal<UsageReminders | undefined>(undefined);
  const [push, setPush] = createSignal<PushService | undefined>(undefined);
  return {
    db,
    settings,
    secrets,
    shell,
    knownHosts,
    keys,
    images,
    machines,
    connector,
    sessions,
    sessionReads: SessionReads.following(db, { sessions, shell, machines }),
    sessionPins: SessionPins.following(db, { sessions, machines }),
    dock: new DockController(machines),
    usageReminders,
    push,
    async startNotifications() {
      const [{ DesktopNotifications }, { UsageReminders }] = await Promise.all([
        import("./notifications/desktop_notifications"),
        import("./notifications/usage_reminders"),
      ]);
      if (isDesktop()) new DesktopNotifications(sessions, shell, settings);
      setUsageReminders(new UsageReminders(settings, sessions, machines));
      if (!shellInfo().push) return;
      const { PushService } = await import("./notifications/push_service");
      setPush(PushService.following({ sessions, shell, machines, settings }));
    },
  };
}

export const AppStateContext = createContext<AppState>();

export function useDatabase(): AppDatabase {
  return useContext(AppStateContext).db;
}

export function useSettings(): SettingsProvider {
  return useContext(AppStateContext).settings;
}

export function useSecrets(): SecretStore {
  return useContext(AppStateContext).secrets;
}

export function useShell(): ShellProvider {
  return useContext(AppStateContext).shell;
}

export function useKnownHosts(): KnownHostsStore {
  return useContext(AppStateContext).knownHosts;
}

export function useKeys(): KeysProvider {
  return useContext(AppStateContext).keys;
}

export function useImages(): MachineImages {
  return useContext(AppStateContext).images;
}

export function useMachines(): MachinesProvider {
  return useContext(AppStateContext).machines;
}

export function useConnector(): MachineConnector {
  return useContext(AppStateContext).connector;
}

export function useSessions(): SessionsProvider {
  return useContext(AppStateContext).sessions;
}

export function useSessionReads(): SessionReads {
  return useContext(AppStateContext).sessionReads;
}

export function useSessionPins(): SessionPins {
  return useContext(AppStateContext).sessionPins;
}

export function useDock(): DockController {
  return useContext(AppStateContext).dock;
}

/** The usage reminders once they started; read it in JSX or an event handler. */
export function useUsageReminders(): Accessor<UsageReminders | undefined> {
  return useContext(AppStateContext).usageReminders;
}

/** Phone push once it started; undefined on a build without push. Read it in JSX, an effect or an event handler. */
export function usePush(): Accessor<PushService | undefined> {
  return useContext(AppStateContext).push;
}
