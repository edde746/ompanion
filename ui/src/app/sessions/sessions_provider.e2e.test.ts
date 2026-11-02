// SessionsProvider against this computer through the core: the cases of test/sessions/sessions_provider_test.dart that
// probe a stand-in omp, and test/sessions/sessions_provider_omp_test.dart against the tested omp with the fake
// provider. Every machine is this computer with an isolated home, so the probe only ever sees the omp the test puts
// there. Needs this computer's omp in `.tools/omp/<version>/` (`scripts/fetch_omp.sh`) and `ui/companion/ompx.js`.
import "../../test/page_globals";
import { afterAll, afterEach, beforeAll, beforeEach, describe, expect, test } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { call } from "../../bridge";
import { compareOmpVersions } from "../../core/host/probe";
import type { LiveSession } from "../../core/session/live_session";
import { OmpStartFailed } from "../../core/session/run_session";
import { modelRefSelector } from "../../core/store/session_view";
import type { BridgeLink } from "../../core/transport/bridge_link";
import { HostLinkException } from "../../core/transport/host_link";
import { localLink, useCore } from "../../test/core";
import { FakeProvider, testedOmpVersion } from "../../test/omp";
import { rejection } from "../../test/scripted_channel";
import { answers, companionBytes, DevMachine, idle, viewWhere } from "../../test/session";
import { AppDatabase } from "../database/app_database";
import { type Machine, type SshMachine, sshEndpoint, sshMachine } from "../models/machine";
import { MachinesProvider } from "../providers/machines_provider";
import { SettingsProvider } from "../providers/settings_provider";
import { KnownHostsStore } from "../services/known_hosts_store";
import { MachineConnector } from "../services/machine_connector";
import { SecretStore } from "../services/secret_store";
import { SessionsProvider } from "./sessions_provider";

useCore();

/** Every machine is this computer with `environment`. */
class LocalConnector extends MachineConnector {
  /** The target host of every link opened. */
  readonly dialed: string[] = [];
  /** While set, connecting fails with it, as with a machine that went off the network. */
  failure: Error | undefined;

  constructor(
    secrets: SecretStore,
    knownHosts: KnownHostsStore,
    private readonly environment: Record<string, string>,
  ) {
    super(secrets, knownHosts);
  }

  override async open(machine: Machine): Promise<BridgeLink> {
    if (this.failure !== undefined) throw this.failure;
    this.dialed.push(machine.kind === "SshMachine" ? machine.target.host : "local");
    return localLink(this.environment);
  }

  override searchSystemPaths(): boolean {
    return false;
  }
}

function machine(options: { name?: string; host?: string } = {}): SshMachine {
  return sshMachine({
    id: "m1",
    name: options.name ?? "box",
    createdAt: Date.UTC(2026, 0, 1),
    updatedAt: Date.UTC(2026, 0, 1),
    target: sshEndpoint({ id: "m1", host: options.host ?? "a.example", user: "me", auth: "agent" }),
  });
}

let machines: MachinesProvider;
let connector: LocalConnector;
let sessions: SessionsProvider;
const cleanups: (() => unknown)[] = [];

/** The providers over this computer with `environment`, from an empty `machines` document. */
async function start(environment: Record<string, string>, companion: () => Promise<Uint8Array>): Promise<void> {
  await call("store.delete", { name: "machines" });
  const db = new AppDatabase();
  const secrets = new SecretStore();
  const knownHosts = new KnownHostsStore(db);
  machines = new MachinesProvider(db, secrets, knownHosts, new SettingsProvider(db));
  await machines.load();
  connector = new LocalConnector(secrets, knownHosts, environment);
  sessions = new SessionsProvider({ connector, machines, deviceId: () => "test", companionBytes: companion });
  cleanups.push(() => sessions.dispose());
}

/** Saves `edited`; the provider ends the runtimes of machines that are not saved. */
async function save(edited: SshMachine): Promise<Machine> {
  await machines.save(edited);
  return machines.byId(edited.id)!;
}

afterEach(async () => {
  for (const cleanup of cleanups.splice(0).reverse()) await cleanup();
});

describe("with a stand-in omp", () => {
  let home: string;

  beforeEach(async () => {
    home = fs.mkdtempSync(path.join(os.tmpdir(), "ompanion-sessions-"));
    cleanups.push(() => fs.rmSync(home, { recursive: true, force: true }));
    await start({ HOME: home, PATH: "/usr/bin:/bin:/usr/sbin:/sbin" }, async () =>
      new TextEncoder().encode("// companion"),
    );
  });

  function installOmp(version: string): void {
    const omp = `${home}/.local/bin/omp`;
    fs.mkdirSync(path.dirname(omp), { recursive: true });
    // omp's standalone binary: Bun itself once BUN_BE_BUN is set.
    fs.writeFileSync(omp, `#!/bin/sh\nif [ -n "$BUN_BE_BUN" ]; then echo 1.4.3; else echo omp/${version}; fi\n`);
    fs.chmodSync(omp, 0o755);
  }

  test("a refresh probes a machine that lacked omp again and finds an install made since", async () => {
    const saved = await save(machine());
    installOmp("18.0.0");
    await sessions.refresh(saved);
    expect(sessions.runtimeFor(saved).status.kind).toBe("MachineNeedsOmp");

    installOmp("18.3.1");
    await sessions.refresh(saved);
    const status = sessions.runtimeFor(saved).status;
    if (status.kind !== "MachineOnline") throw new Error(`not online: ${status.kind}`);
    expect(status.probe.ompVersion).toBe("18.3.1");
  });

  test("an edit of the route connects anew; a rename keeps the connection", async () => {
    const saved = await save(machine());
    await sessions.refresh(saved);
    const runtime = sessions.runtimeFor(saved);

    const renamed = await save(machine({ name: "renamed" }));
    expect(sessions.runtimeFor(renamed)).toBe(runtime);

    const moved = await save(machine({ name: "renamed", host: "b.example" }));
    await sessions.refresh(moved);
    expect(connector.dialed).toEqual(["a.example", "b.example"]);
  });
});

describe("with the tested omp and the fake provider", () => {
  let fake: FakeProvider;
  let dev: DevMachine;
  let saved: Machine;

  beforeAll(async () => {
    fake = await FakeProvider.start();
    dev = await DevMachine.create(fake.port);
  }, 60_000);

  afterAll(async () => {
    await dev.dispose();
    await fake.stop();
  });

  beforeEach(async () => {
    await fake.reset();
    await start(dev.environment, companionBytes);
    saved = await save(machine({ name: "dev", host: "dev.example" }));
  });

  /** A new session in the dev machine's project, after its first turn (the fake provider answers `ok`). */
  async function answered(model?: string): Promise<LiveSession> {
    const session = await sessions.open(saved, { kind: "NewSession", cwd: dev.project, model });
    // omp writes the session file with the turn.
    await session.rpc.prompt("hello");
    await viewWhere(session, (view) => idle(view) && answers(view).length > 0);
    return session;
  }

  test("a stop that cannot reach the machine keeps the session open and throws", async () => {
    const session = await sessions.open(saved, { kind: "NewSession", cwd: dev.project });
    sessions.select(session);
    connector.failure = new HostLinkException("the machine is off the network");
    await sessions.runtimeFor(saved).link.close();

    expect(await rejection(sessions.stop(session))).toBeInstanceOf(HostLinkException);
    expect(sessions.openSessions()).toHaveLength(1);
    expect(sessions.openSessions()[0]).toBe(session);
    expect(sessions.active()).toBe(session);

    connector.failure = undefined;
    await sessions.stop(session);
    expect(sessions.openSessions()).toHaveLength(0);
  });

  test("an open, and one of a closed session again in its place, leaves the shown session shown", async () => {
    const first = await answered();
    sessions.select(first);
    const sessionPath = first.sessionPath!;
    const second = await sessions.open(saved, { kind: "NewSession", cwd: dev.project });
    expect(sessions.active()).toBe(first);
    sessions.select(second);
    await first.stop();

    const reopened = await sessions.open(saved, { kind: "ResumeSession", sessionPath });
    expect(reopened).not.toBe(first);
    const open = sessions.openSessions();
    expect(open).toHaveLength(2);
    expect(open[0]).toBe(reopened);
    expect(open[1]).toBe(second);
    expect(sessions.active()).toBe(second);

    await sessions.stop(reopened);
    await sessions.stop(second);
  });

  // Older omp continued such a session on another model by itself.
  test.skipIf(compareOmpVersions(testedOmpVersion, "18.6.3") < 0)(
    "a session whose model omp cannot restore opens on the model the user picks, or stays closed",
    async () => {
      const first = await answered("fake/fake-think");
      const sessionPath = first.sessionPath!;
      await sessions.stop(first);
      // The model leaves omp's list, as a model dropped from models.yml or a provider signed out of does.
      const models = `${dev.home}/.omp/agent/models.yml`;
      const original = fs.readFileSync(models, "utf8");
      cleanups.push(() => fs.writeFileSync(models, original));
      fs.writeFileSync(models, original.replace(/ {6}- id: fake-think\n( {8}.*\n)*/, ""));

      const asked: string[] = [];
      const declined = sessions.open(
        saved,
        { kind: "ResumeSession", sessionPath },
        {
          chooseModel: async (_machine, missing) => {
            asked.push(missing);
            return undefined;
          },
        },
      );
      expect(await rejection(declined)).toBeInstanceOf(OmpStartFailed);
      const reopened = await sessions.open(
        saved,
        { kind: "ResumeSession", sessionPath },
        {
          chooseModel: async (_machine, missing) => {
            asked.push(missing);
            return "fake/fake-1";
          },
        },
      );
      expect(asked).toEqual(["fake/fake-think", "fake/fake-think"]);
      await viewWhere(
        reopened,
        (view) => view.config.model !== undefined && modelRefSelector(view.config.model) === "fake/fake-1",
      );
      await sessions.stop(reopened);
    },
  );
});
