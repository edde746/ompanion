import "../../test/page_globals";
import { expect, test } from "bun:test";
import { call } from "../../bridge";
import { FormatException } from "../../core/rpc/json_fields";
import { useMemoryCore } from "../../test/memory_core";
import { AppDatabase } from "../database/app_database";
import { KnownHostsStore } from "./known_hosts_store";

useMemoryCore();

test("a known_hosts document that does not read fails host key checks instead of holding them", async () => {
  await call("store.write", { name: "known_hosts", text: "{}" });
  const store = new KnownHostsStore(new AppDatabase());
  const verify = await store.verifier(async () => true);
  const check = verify({
    host: "build",
    port: 22,
    keyType: "ssh-ed25519",
    keyBlob: new Uint8Array([1, 2, 3]),
    sha256Fingerprint: "SHA256:AQID",
  }).catch((error: unknown) => error);

  await expect(store.load()).rejects.toThrow("expected an array");
  expect(await check).toBeInstanceOf(FormatException);
});

test("a boot that fails before the documents load fails what waits for them", async () => {
  const store = new KnownHostsStore(new AppDatabase());
  store.failLoad(new Error("settings did not load"));

  await expect(store.forgetWhere(() => true)).rejects.toThrow("settings did not load");
});
