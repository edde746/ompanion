// A machine where omp finds no usable model refuses rpc mode. The control session comes up in bootstrap mode, and a
// key stored through it turns the machine into a normal one. Every process runs behind a proxy that forwards nothing,
// so no request leaves this computer.
import { afterEach, expect, test } from "bun:test";
import * as fs from "node:fs";
import { Cleanups } from "../../test/cleanups";
import { useCore } from "../../test/core";
import { FakeProvider } from "../../test/omp";
import { rejection } from "../../test/scripted_channel";
import { answers, DevMachine, idle, ProxyRecorder, viewWhere } from "../../test/session";
import { ensureAppDir, hostPath, newMarker } from "../host/scripts";
import { asJsonObject, isJsonObject, type JsonObject, list } from "../rpc/json_fields";

useCore();

const cleanups = new Cleanups();

afterEach(() => cleanups.run());

function providerRow(accounts: JsonObject, provider: string): JsonObject {
  const rows = list(accounts, "providers").filter(isJsonObject);
  const matching = rows.filter((row) => row["provider"] === provider);
  expect(matching).toHaveLength(1);
  return matching[0]!;
}

test("without a usable model the control runs in bootstrap mode until a key is stored", async () => {
  const fake = await FakeProvider.start();
  cleanups.add(() => fake.stop());
  const proxy = new ProxyRecorder();
  cleanups.add(() => proxy.close());
  const machine = await DevMachine.create(fake.port);
  cleanups.add(() => machine.dispose());
  // The fake provider without a credential: `auth: oauth` needs none in models.yml, and omp has none stored.
  const models = `${machine.home}/.omp/agent/models.yml`;
  fs.writeFileSync(models, fs.readFileSync(models, "utf8").replace("    apiKey: fake-key\n", "    auth: oauth\n"));
  const runtime = machine.runtime("device-a", { extraEnvironment: proxy.environment });
  cleanups.add(() => runtime.dispose());

  const bootstrap = await runtime.control();
  expect(runtime.controlIsBootstrap).toBe(true);
  expect((await bootstrap.rpc.getState()).model?.id).toBe("MiniMax-M2");
  const settings = asJsonObject(await bootstrap.companion.call("settings.get", { paths: ["speech.enabled"] }), "result");
  expect(settings["settings"]).toEqual([{ path: "speech.enabled", value: false, provenance: "overlay" }]);
  // No model call in bootstrap mode.
  expect(await rejection(bootstrap.rpc.prompt("Hello?"))).toBeInstanceOf(Error);
  expect(await rejection(bootstrap.companion.call("btw", { prompt: "Hello?" }))).toBeInstanceOf(Error);
  // The provider models.yml configures has no credential, yet the accounts list names it, so the app offers its key
  // field; the placeholder provider is the current one.
  const before = asJsonObject(await bootstrap.companion.call("accounts.list"), "accounts");
  expect(before["currentProvider"]).toBe("minimax");
  const keyless = providerRow(before, "fake");
  expect([keyless["source"] ?? null, keyless["credentials"]]).toEqual([null, []]);

  const files = await runtime.link.files();
  let keyFile: string;
  try {
    keyFile = `${await ensureAppDir(files, "tmp")}/${newMarker()}.secret`;
    await files.write(keyFile, new TextEncoder().encode("fake-key\n"), { mode: 0o600 });
  } finally {
    await files.close();
  }
  const stored = asJsonObject(
    await bootstrap.companion.call("accounts.setKey", { provider: "fake", keyFile: hostPath(keyFile) }),
    "stored",
  );
  expect(stored["provider"]).toBe("fake");
  // The companion deletes the key file.
  expect(fs.existsSync(hostPath(keyFile))).toBe(false);

  const control = await runtime.control();
  expect(control).not.toBe(bootstrap);
  // A new omp found the stored key.
  expect(runtime.controlIsBootstrap).toBe(false);
  expect(bootstrap.linkState.kind).toBe("LinkClosed");
  const accounts = asJsonObject(await control.companion.call("accounts.list"), "accounts");
  const credentials = list(providerRow(accounts, "fake"), "credentials").filter(isJsonObject);
  expect(credentials.map((credential) => credential["type"])).toEqual(["api_key"]);

  await fake.enqueue([{ steps: [{ text: "Answered with the stored key." }] }]);
  const session = await runtime.open({ kind: "NewSession", cwd: machine.project, model: "fake/fake-1" });
  await session.rpc.prompt("Hello?");
  const done = await viewWhere(session, (view) => idle(view) && answers(view).length > 0);
  expect(answers(done)).toEqual(["Answered with the stored key."]);
  // omp's startup fetches public model catalogs (kilo, venice, zenmux, …); they came here and were refused.
  expect(proxy.requests.length).toBeGreaterThan(0);
  expect(proxy.requests.filter((request) => request.includes("minimax"))).toEqual([]);
  // Only HTTPS, all refused.
  expect(proxy.requests.filter((request) => !request.startsWith("CONNECT "))).toEqual([]);
}, 120_000);
