// The contracts lib/notifications/push_service.dart's doc comments state (the Flutter app had no test of it), over the
// memory core, which plays the shell's push side (`shell.push*` and its events), and two machines whose runtimes the
// tests bring online.
import "../../test/page_globals";
import { afterEach, expect, test } from "bun:test";
import { type Accessor, createSignal, flush, type Setter } from "solid-js";
import { BridgeError } from "../../bridge";
import { pushRelayUrl } from "../../core/host/push_registration";
import type { LiveSession } from "../../core/session/live_session";
import { type MachineRuntime, type MachineStatus, machineOffline } from "../../core/session/machine_runtime";
import { type HostLink, HostLinkException } from "../../core/transport/host_link";
import { Emitter, type EventStream } from "../../core/util/stream";
import { FakeLiveSession, settle } from "../../test/live_session";
import { useMemoryCore } from "../../test/memory_core";
import { MemoryFiles, MemoryLink, memoryProbe } from "../../test/memory_host";
import { rejection } from "../../test/scripted_channel";
import { AppDatabase } from "../database/app_database";
import { localMachine, type Machine } from "../models/machine";
import { MachinesProvider } from "../providers/machines_provider";
import { Prefs, SettingsProvider } from "../providers/settings_provider";
import { ShellProvider } from "../providers/shell_provider";
import { KnownHostsStore } from "../services/known_hosts_store";
import { MachineConnector } from "../services/machine_connector";
import { SecretStore } from "../services/secret_store";
import { SessionsProvider } from "../sessions/sessions_provider";
import { type PushFailure, PushService } from "./push_service";

const core = useMemoryCore();
const deviceId = "00112233445566778899aabbccddeeff";
const registrationPath = `/home/test/.ompanion/push/${deviceId}.json`;
const db = new AppDatabase();
const secrets = new SecretStore();
const knownHosts = new KnownHostsStore(db);
const box = localMachine({ id: "m1", name: "box", createdAt: 0, updatedAt: 0 });
const laptop = localMachine({ id: "m2", name: "laptop", createdAt: 0, updatedAt: 0 });

/** What the push service uses of a machine's runtime: its status, the statuses it emits, and a link to its files. */
class FakeRuntime {
  status: MachineStatus = machineOffline;
  readonly files = new MemoryFiles();
  readonly link: HostLink = new MemoryLink(this.files);
  private readonly emitter = new Emitter<MachineStatus>();

  get statuses(): EventStream<MachineStatus> {
    return this.emitter.stream;
  }

  goOnline(): void {
    this.status = { kind: "MachineOnline", probe: memoryProbe() };
    this.emitter.add(this.status);
  }

  /** The registration file this phone has on the machine, decoded; undefined when there is none. */
  registration(): unknown {
    const bytes = this.files.files.get(registrationPath);
    return bytes === undefined ? undefined : JSON.parse(new TextDecoder().decode(bytes));
  }
}

/** `box` and `laptop`, as loaded. */
class FixedMachines extends MachinesProvider {
  constructor() {
    super(db, secrets, knownHosts, new SettingsProvider(db));
  }

  override machines(): readonly Machine[] {
    return [box, laptop];
  }
}

/** What the push service uses of SessionsProvider: each machine's {@link FakeRuntime}, and the session on screen. */
class FakeSessions extends SessionsProvider {
  readonly fakes = new Map([
    [box.id, new FakeRuntime()],
    [laptop.id, new FakeRuntime()],
  ]);
  readonly showSession: Setter<LiveSession | undefined>;
  private readonly onScreen: Accessor<LiveSession | undefined>;

  constructor(machines: MachinesProvider) {
    super({
      connector: new MachineConnector(secrets, knownHosts),
      machines,
      deviceId: () => deviceId,
      companionBytes: async () => new Uint8Array(),
    });
    [this.onScreen, this.showSession] = createSignal<LiveSession | undefined>(undefined);
  }

  fake(machine: Machine): FakeRuntime {
    const runtime = this.fakes.get(machine.id);
    if (runtime === undefined) throw new Error(`no runtime for ${machine.id}`);
    return runtime;
  }

  override runtimeFor(machine: Machine): MachineRuntime {
    // The service reads only `status`, `statuses` and `link`; a real runtime needs the core and a machine.
    return this.fake(machine) as unknown as MachineRuntime;
  }

  override active(): LiveSession | undefined {
    return this.onScreen();
  }

  override machineOf(session: LiveSession): Machine | undefined {
    return session === this.onScreen() ? box : undefined;
  }
}

interface Started {
  readonly push: PushService;
  readonly sessions: FakeSessions;
  readonly settings: SettingsProvider;
  readonly shell: ShellProvider;
  readonly failures: PushFailure[];
}

const cleanups: (() => void)[] = [];

afterEach(() => {
  for (const cleanup of cleanups.splice(0).reverse()) cleanup();
});

/** A push service as boot starts it, with push on or off, once it has taken the shell's registration. */
async function start(options: { on: boolean }): Promise<Started> {
  const settings = new SettingsProvider(db);
  await settings.set(Prefs.pushNotifications, options.on);
  const machines = new FixedMachines();
  const sessions = new FakeSessions(machines);
  const shell = new ShellProvider();
  const push = PushService.following({ sessions, shell, machines, settings });
  const failures: PushFailure[] = [];
  const subscription = push.failures.listen((failure) => failures.push(failure));
  cleanups.push(() => {
    subscription.cancel();
    push.dispose();
    sessions.dispose();
  });
  await idle();
  return { push, sessions, settings, shell, failures };
}

/** Lets the shell's answers and events land, the effects they set off run, and the registration writes finish. */
async function idle(): Promise<void> {
  await core.settled();
  flush();
  await core.settled();
  await settle();
}

const androidKey = { platform: "android", fid: "fid-1", key: "key-1" };

test("turning push on writes the registration to the connected machines, and to the others as they connect", async () => {
  const { push, sessions, settings } = await start({ on: false });
  await settings.set(Prefs.pushRemovals, [laptop.id]);
  sessions.fake(box).goOnline();
  core.push.registration = androidKey;

  await push.enable();
  await idle();

  expect(core.push.requests).toContainEqual({ method: "shell.pushEnable", params: { deviceId } });
  expect(settings.get(Prefs.pushNotifications)).toBe(true);
  expect(settings.get(Prefs.pushRemovals)).toEqual([]);
  expect(sessions.fake(box).registration()).toEqual({
    v: 1,
    deviceId,
    machineId: "m1",
    machineName: "box",
    platform: "android",
    fid: "fid-1",
    key: "key-1",
    kinds: ["input", "done", "failed"],
    relay: pushRelayUrl,
  });
  expect(sessions.fake(laptop).registration()).toBeUndefined();

  sessions.fake(laptop).goOnline();
  await idle();

  expect(sessions.fake(laptop).registration()).toMatchObject({ machineId: "m2", machineName: "laptop", fid: "fid-1" });
});

test("a refused enable leaves push off, carries the shell's code and ends busy", async () => {
  const { push, settings } = await start({ on: false });
  core.push.enableError = "denied";

  const error = await rejection(push.enable());

  expect(error instanceof BridgeError && error.code).toBe("denied");
  expect(push.busy()).toBe(false);
  expect(settings.get(Prefs.pushNotifications)).toBe(false);
});

test("turning push off removes the registration from the connected machines, and from the others as they connect", async () => {
  core.push.registration = { ...androidKey, platform: "ios" };
  const { push, sessions, settings } = await start({ on: true });
  sessions.fake(box).goOnline();
  await idle();
  expect(sessions.fake(box).registration()).toMatchObject({ platform: "ios" });
  // Written on an earlier connect, which this run of the app did not see.
  sessions.fake(laptop).files.put(registrationPath, new TextEncoder().encode("{}\n"));

  await push.disable();
  await idle();

  expect(core.push.requests.map((request) => request.method)).toContain("shell.pushDisable");
  expect(settings.get(Prefs.pushNotifications)).toBe(false);
  expect(sessions.fake(box).registration()).toBeUndefined();
  expect(settings.get(Prefs.pushRemovals)).toEqual([laptop.id]);

  sessions.fake(laptop).goOnline();
  await idle();

  expect(sessions.fake(laptop).registration()).toBeUndefined();
  expect(settings.get(Prefs.pushRemovals)).toEqual([]);
});

test("push on without a key on the phone turns push off and removes the registrations the machines hold", async () => {
  // No registration on the phone: a restore from a backup brought the setting and not the key.
  const { push, sessions, settings } = await start({ on: true });

  expect(core.push.requests.map((request) => request.method)).toContain("shell.pushRegistration");
  expect(push.lostKey()).toBe(true);
  expect(push.enabled()).toBe(false);
  expect(settings.get(Prefs.pushRemovals)).toEqual([box.id, laptop.id]);

  sessions.fake(box).files.put(registrationPath, new TextEncoder().encode("{}\n"));
  sessions.fake(box).goOnline();
  await idle();

  expect(sessions.fake(box).registration()).toBeUndefined();
  expect(settings.get(Prefs.pushRemovals)).toEqual([laptop.id]);
});

test("a new FID is written to the connected machines", async () => {
  core.push.registration = androidKey;
  const { sessions } = await start({ on: true });
  sessions.fake(box).goOnline();
  await idle();
  expect(sessions.fake(box).registration()).toMatchObject({ fid: "fid-1" });

  core.event("shell.pushFid", { fid: "fid-2" });
  await idle();

  expect(sessions.fake(box).registration()).toMatchObject({ fid: "fid-2", key: "key-1" });
});

test("changing the wanted kinds writes the registrations again", async () => {
  core.push.registration = androidKey;
  const { sessions, settings } = await start({ on: true });
  sessions.fake(box).goOnline();
  await idle();

  await settings.set(Prefs.notify("done"), false);
  await idle();

  expect(sessions.fake(box).registration()).toMatchObject({ kinds: ["input", "failed"] });
});

test("a registration write that fails lands on failures with its machine", async () => {
  core.push.registration = androidKey;
  const { sessions, failures } = await start({ on: true });
  sessions.fake(box).files.write = async () => {
    throw new HostLinkException("disk full");
  };

  sessions.fake(box).goOnline();
  await idle();

  expect(failures).toHaveLength(1);
  expect(failures[0]?.machine).toBe(box);
  expect(String(failures[0]?.error)).toContain("disk full");
});

test("the shell hears which session is on screen while the app is in front, and that session's notifications clear", async () => {
  const { sessions, shell } = await start({ on: false });
  const visibility = () =>
    core.push.requests.filter(
      (request) => request.method === "shell.pushSetVisible" || request.method === "shell.pushClear",
    );
  const shown = { method: "shell.pushSetVisible", params: { machineId: "m1", runId: "run" } };
  const cleared = { method: "shell.pushClear", params: { machineId: "m1", runId: "run" } };
  const none = { method: "shell.pushSetVisible", params: {} };

  sessions.showSession(new FakeLiveSession());
  await idle();
  expect(visibility()).toEqual([]);

  shell.select({ kind: "SessionSelection" });
  await idle();
  core.event("shell.appState", { active: false });
  await idle();
  core.event("shell.appState", { active: true });
  await idle();
  shell.select({ kind: "SettingsSelection" });
  await idle();

  expect(visibility()).toEqual([shown, cleared, none, shown, cleared, none]);
});

test("the launch tap decodes to its target, and to nothing when no notification launched the app", async () => {
  const { push } = await start({ on: false });
  core.push.launchTap = { machineId: "m1", runId: null, sessionPath: "/home/test/s.jsonl" };

  expect(await push.takeLaunchTap()).toEqual({ machineId: "m1", sessionPath: "/home/test/s.jsonl" });
  expect(await push.takeLaunchTap()).toBeUndefined();
});
