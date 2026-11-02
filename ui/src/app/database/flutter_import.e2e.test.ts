// The import of the Flutter app's data against the seed's databases (harness/flutter-seed): the real core reads them
// with `sqlite.read`, and the dev bridge plays the shell, answering `shell.flutterData` from $OMPCORE_FLUTTER_DB and
// $OMPCORE_FLUTTER_SECRETS and setting the files aside on `shell.flutterDataClear`. What lands in the documents and
// secrets must be what the seed's expected*.json say.
import { afterAll, beforeEach, expect, test } from "bun:test";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import { BridgeError, call } from "../../bridge";
import { useCore } from "../../test/core";
import { AppDatabase } from "./app_database";
import { flutterData } from "./flutter_data";
import { importFlutterData } from "./flutter_import";

const seed = path.resolve(import.meta.dir, "../../../../harness/flutter-seed");
const dir = await fs.mkdtemp(path.join(os.tmpdir(), "flutter-import-"));
const database = path.join(dir, "ompanion.sqlite");
const secretsFile = path.join(dir, "secrets.json");
// Read by the dev bridge on every call; set before useCore starts it.
process.env.OMPCORE_FLUTTER_DB = database;
process.env.OMPCORE_FLUTTER_SECRETS = secretsFile;

useCore();

afterAll(async () => {
  delete process.env.OMPCORE_FLUTTER_DB;
  delete process.env.OMPCORE_FLUTTER_SECRETS;
  await fs.rm(dir, { recursive: true, force: true });
});

interface Expected {
  readonly store: Readonly<Record<string, unknown>>;
  readonly secrets?: Readonly<Record<string, string>>;
}

async function readJson(file: string): Promise<Expected> {
  return (await Bun.file(path.join(seed, file)).json()) as Expected;
}

const documents = ["machines", "keys", "known_hosts", "settings", "read_markers", "pinned_sessions"];
const secrets = (await readJson("expected.json")).secrets ?? {};

beforeEach(async () => {
  for (const name of documents) await call("store.delete", { name });
  for (const file of await fs.readdir(dir)) await fs.rm(path.join(dir, file));
});

for (const [schema, fixture, expectedFile] of [
  ["v1", "fixtures/flutter-v1.sqlite", "fixtures/expected-v1.json"],
  ["v2", "fixtures/flutter-v2.sqlite", "fixtures/expected-v2.json"],
  ["v3", "fixtures/flutter-v3.sqlite", "expected.json"],
] as const) {
  test(`a schema ${schema} database and the secrets become the expected documents and secrets`, async () => {
    const expected = await readJson(expectedFile);
    await fs.copyFile(path.join(seed, fixture), database);
    await Bun.write(secretsFile, JSON.stringify(secrets));

    const data = await flutterData();
    expect(data).toEqual({ database, secrets });
    await importFlutterData(new AppDatabase(), data);

    for (const name of documents) {
      const { text } = await call<{ text: string | null }>("store.read", { name });
      // A table the database lacks makes no document.
      const rows = name in expected.store ? expected.store[name] : null;
      expect({ name, rows: JSON.parse(text ?? "null") as unknown }).toEqual({ name, rows });
    }
    for (const [key, value] of Object.entries(secrets)) {
      expect(await call<{ value: string | null }>("shell.secretGet", { key })).toEqual({ value });
    }
    // Set aside: the database renamed as the user's backup, the old secrets gone.
    expect(await flutterData()).toEqual({ database: null, secrets: {} });
    expect(await fs.readdir(dir)).toEqual(["ompanion.sqlite.imported"]);
  });
}

test("a database that is not one fails the import and leaves the Flutter data where it is", async () => {
  await Bun.write(database, "This is not an SQLite database, it only has the name of one.\n");
  await Bun.write(secretsFile, JSON.stringify(secrets));

  const data = await flutterData();
  const failure = await importFlutterData(new AppDatabase(), data).then(
    () => undefined,
    (error: unknown) => error,
  );
  expect(failure).toBeInstanceOf(BridgeError);
  expect(failure instanceof BridgeError && failure.code).toBe("malformed");

  for (const name of documents) {
    expect(await call<{ text: string | null }>("store.read", { name })).toEqual({ text: null });
  }
  expect(await flutterData()).toEqual(data);
});
