// Port of test/sessions/sessions_provider_test.dart, the case that needs no core; the cases that probe this computer
// through the core are in sessions_provider.e2e.test.ts.
import "../../test/page_globals";
import { expect, test } from "bun:test";
import { RpcCommandException } from "../../core/rpc/exceptions";
import { RpcClient } from "../../core/rpc/rpc_client";
import { rejection, ScriptedChannel } from "../../test/scripted_channel";
import { AppDatabase } from "../database/app_database";
import { sshEndpoint, sshMachine } from "../models/machine";
import { MachinesProvider } from "../providers/machines_provider";
import { SettingsProvider } from "../providers/settings_provider";
import { KnownHostsStore } from "../services/known_hosts_store";
import { MachineConnector } from "../services/machine_connector";
import { SecretStore } from "../services/secret_store";
import { SessionsProvider } from "./sessions_provider";

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
