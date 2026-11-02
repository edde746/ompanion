// What the Flutter app left on this device (docs/contracts/bridge.md, `shell.flutterData`): its database file and its
// secrets. Boot asks once per launch; only when something is there does the import's code load.
import { call } from "../../bridge";
import { asJsonObject, FormatException, object, optString } from "../../core/rpc/json_fields";

export interface FlutterData {
  /** The absolute path of the Flutter app's `ompanion.sqlite`, or null when there is none. */
  readonly database: string | null;
  /** Every flutter_secure_storage entry, by its key. */
  readonly secrets: Readonly<Record<string, string>>;
}

export async function flutterData(): Promise<FlutterData> {
  const json = asJsonObject(await call<unknown>("shell.flutterData"), "shell.flutterData");
  const secrets: Record<string, string> = {};
  for (const [key, value] of Object.entries(object(json, "secrets"))) {
    if (typeof value !== "string") throw new FormatException(`shell.flutterData: secret ${key} is not a string`);
    secrets[key] = value;
  }
  return { database: optString(json, "database") ?? null, secrets };
}

export function hasFlutterData(data: FlutterData): boolean {
  return data.database !== null || Object.keys(data.secrets).length > 0;
}
