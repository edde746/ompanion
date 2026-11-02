// Port of test/sessions/show_session_test.dart.
import "../../test/page_globals";
import { expect, test } from "bun:test";
import { flush } from "solid-js";
import type { LiveSession } from "../../core/session/live_session";
import type { SessionOpen } from "../../core/session/machine_runtime";
import { type Deferred, deferred } from "../../deferred";
import { FakeLiveSession } from "../../test/live_session";
import { AppDatabase } from "../database/app_database";
import { localMachine, type Machine } from "../models/machine";
import { MachinesProvider } from "../providers/machines_provider";
import { SettingsProvider } from "../providers/settings_provider";
import { ShellProvider } from "../providers/shell_provider";
import { KnownHostsStore } from "../services/known_hosts_store";
import { MachineConnector } from "../services/machine_connector";
import { SecretStore } from "../services/secret_store";
import { SessionsProvider } from "./sessions_provider";
import { showSession } from "./show_session";

const machine = localMachine({ id: "m1", name: "box", createdAt: 0, updatedAt: 0 });
const db = new AppDatabase();
const secrets = new SecretStore();
const knownHosts = new KnownHostsStore(db);

/**
 * What showSession uses of SessionsProvider: no session open on this device yet, attaches to runs that open when the
 * test resolves them in `opening`, and the session `select` chose.
 */
class OpeningSessions extends SessionsProvider {
  readonly opening = new Map<string, Deferred<LiveSession>>();
  selected: LiveSession | undefined;

  constructor() {
    super({
      connector: new MachineConnector(secrets, knownHosts),
      machines: new MachinesProvider(db, secrets, knownHosts, new SettingsProvider(db)),
      deviceId: () => "test",
      companionBytes: async () => new Uint8Array(),
    });
  }

  override openSessions(): readonly LiveSession[] {
    return [];
  }

  override machineOf(): Machine | undefined {
    return machine;
  }

  override open(_machine: Machine, request: SessionOpen): Promise<LiveSession> {
    if (request.kind !== "AttachRun") throw new Error(`unexpected ${request.kind}`);
    let opening = this.opening.get(request.runId);
    if (opening === undefined) this.opening.set(request.runId, (opening = deferred<LiveSession>()));
    return opening.promise;
  }

  override select(session: LiveSession): void {
    this.selected = session;
  }
}

const noModel = async () => undefined;

test("of two sessions still opening, the one clicked last shows, whichever opens first", async () => {
  const sessions = new OpeningSessions();
  const shell = new ShellProvider();
  const first = showSession(sessions, shell, machine, { runId: "a", chooseModel: noModel });
  const second = showSession(sessions, shell, machine, { runId: "b", chooseModel: noModel });

  sessions.opening.get("a")!.resolve(new FakeLiveSession());
  await first;
  flush();
  expect(sessions.selected).toBeUndefined();
  expect(shell.selection().kind).toBe("HomeSelection");

  const b = new FakeLiveSession();
  sessions.opening.get("b")!.resolve(b);
  await second;
  flush();
  expect(sessions.selected).toBe(b);
  expect(shell.selection().kind).toBe("SessionSelection");
  sessions.dispose();
});

test("a session that opens after the user went elsewhere leaves them there", async () => {
  const sessions = new OpeningSessions();
  const shell = new ShellProvider();
  const opening = showSession(sessions, shell, machine, { runId: "a", chooseModel: noModel });
  shell.select({ kind: "SettingsSelection" });

  sessions.opening.get("a")!.resolve(new FakeLiveSession());
  await opening;
  flush();
  expect(sessions.selected).toBeUndefined();
  expect(shell.selection().kind).toBe("SettingsSelection");
  sessions.dispose();
});
