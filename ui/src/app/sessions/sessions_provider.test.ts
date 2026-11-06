// Port of test/sessions/sessions_provider_test.dart, the case that needs no core; the cases that probe this computer
// through the core are in sessions_provider.e2e.test.ts.
import "../../test/page_globals";
import { expect, test } from "bun:test";
import type { SessionSummary } from "../../core/host/session_listing";
import { RpcCommandException } from "../../core/rpc/exceptions";
import { RpcClient } from "../../core/rpc/rpc_client";
import type { LocalForward, MachineRuntime } from "../../core/session/machine_runtime";
import { deferred } from "../../deferred";
import { FakeLiveSession } from "../../test/live_session";
import { rejection, ScriptedChannel } from "../../test/scripted_channel";
import { AppDatabase } from "../database/app_database";
import { type Machine, sshEndpoint, sshMachine } from "../models/machine";
import { MachinesProvider } from "../providers/machines_provider";
import { SettingsProvider } from "../providers/settings_provider";
import { KnownHostsStore } from "../services/known_hosts_store";
import { MachineConnector } from "../services/machine_connector";
import { SecretStore } from "../services/secret_store";
import { SessionsProvider } from "./sessions_provider";

const box = sshMachine({
  id: "m1",
  name: "box",
  createdAt: Date.UTC(2026, 0, 1),
  updatedAt: Date.UTC(2026, 0, 1),
  target: sshEndpoint({ id: "m1", host: "a.example", user: "me", auth: "agent" }),
});

/** Only `box`, as loaded. */
class OneMachine extends MachinesProvider {
  override machines(): readonly Machine[] {
    return [box];
  }
}

/** A provider whose `box` runtime is online and lists what `list` returns; nothing reaches a core. */
function onlineProvider(list: () => Promise<SessionSummary[]> = async () => []): {
  sessions: SessionsProvider;
  runtime: MachineRuntime;
} {
  const db = new AppDatabase();
  const secrets = new SecretStore();
  const knownHosts = new KnownHostsStore(db);
  const sessions = new SessionsProvider({
    connector: new MachineConnector(secrets, knownHosts),
    machines: new OneMachine(db, secrets, knownHosts, new SettingsProvider(db)),
    deviceId: () => "test",
    companionBytes: async () => new Uint8Array(),
  });
  const runtime = sessions.runtimeFor(box);
  Object.defineProperty(runtime, "status", { value: { kind: "MachineOnline" } });
  runtime.listSessions = list;
  return { sessions, runtime };
}

function summary(path: string): SessionSummary {
  return { path, size: 1, modifiedMs: 1, id: path };
}

class TrackedSession extends FakeLiveSession {
  detached = false;

  override async detach(): Promise<void> {
    this.detached = true;
  }
}

test("a failed model list is fetched again and leaves no unhandled error", async () => {
  const db = new AppDatabase();
  const secrets = new SecretStore();
  const knownHosts = new KnownHostsStore(db);
  const sessions = new SessionsProvider({
    connector: new MachineConnector(secrets, knownHosts),
    machines: new MachinesProvider(db, secrets, knownHosts, new SettingsProvider(db)),
    deviceId: () => "test",
    companionBytes: async () => new Uint8Array(),
  });
  // omp answers every command but `get_available_models`, which fails.
  const omp = new ScriptedChannel();
  omp.answer("negotiate_protocol", () => ({ protocolVersion: 2 }));
  omp.sentCommands
    .where((command) => command.type === "get_available_models")
    .listen((command) => omp.reject(command, "models unavailable"));
  const rpc = new RpcClient(omp, { deviceId: "test" });
  await rpc.attach();
  const machine = sshMachine({
    id: "m1",
    name: "box",
    createdAt: Date.UTC(2026, 0, 1),
    updatedAt: Date.UTC(2026, 0, 1),
    target: sshEndpoint({ id: "m1", host: "a.example", user: "me", auth: "agent" }),
  });

  expect(await rejection(sessions.models(machine, rpc))).toBeInstanceOf(RpcCommandException);
  expect(await rejection(sessions.models(machine, rpc))).toBeInstanceOf(RpcCommandException);
  expect(omp.sent.filter((command) => command.type === "get_available_models")).toHaveLength(2);
  await rpc.close();
  sessions.dispose();
});

test("of overlapping listings of one machine, the newest one's result stays", async () => {
  const listings = [deferred<SessionSummary[]>(), deferred<SessionSummary[]>(), deferred<SessionSummary[]>()];
  let calls = 0;
  const { sessions } = onlineProvider(() => listings[calls++]!.promise);

  const older = sessions.refresh(box);
  const failing = sessions.refresh(box);
  const newer = sessions.refresh(box);
  listings[2]!.resolve([summary("/new.jsonl")]);
  await newer;
  listings[0]!.resolve([summary("/old.jsonl")]);
  listings[1]!.reject(new Error("listing failed"));
  await Promise.all([older, failing]);

  const listing = sessions.listingOf(box);
  expect(listing.sessions.map((session) => session.path)).toEqual(["/new.jsonl"]);
  expect(listing.error).toBeUndefined();
  expect(listing.loading).toBe(false);
  sessions.dispose();
});

test("a reopen that ends after its session was detached does not bring the session back", async () => {
  const { sessions, runtime } = onlineProvider();
  const first = new TrackedSession();
  runtime.open = async () => first;
  await sessions.open(box, { kind: "AttachRun", runId: "run" });
  const launched = deferred<TrackedSession>();
  runtime.open = () => launched.promise;

  const reopened = rejection(sessions.reopen(first));
  await sessions.detach(first);
  const second = new TrackedSession();
  launched.resolve(second);

  expect(await reopened).toBeInstanceOf(Error);
  expect(sessions.openSessions()).toEqual([]);
  expect(second.detached).toBe(true);
  sessions.dispose();
});

test("two logins on one machine and port share the forward that is still opening", async () => {
  const { sessions, runtime } = onlineProvider();
  const opened = deferred<LocalForward>();
  let forwards = 0;
  runtime.forwardLocal = () => {
    forwards++;
    return opened.promise;
  };
  const url = `https://auth.example/authorize?redirect_uri=${encodeURIComponent("http://localhost:1455/callback")}`;

  const logins = [sessions.forwardOAuthCallback(box, url), sessions.forwardOAuthCallback(box, url)];
  const forward: LocalForward = { localPort: 1455, remotePort: 1455, close: async () => {} };
  opened.resolve(forward);

  expect(await Promise.all(logins)).toEqual([forward, forward]);
  expect(forwards).toBe(1);
  sessions.dispose();
});
