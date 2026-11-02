// Port of packages/omp_core/lib/src/rpc/json_fields.dart. Dart's `JsonFields` extension methods are free functions
// taking the object first; a Dart null comes back as `undefined`.

/** A decoded JSON object (Dart's `Map<String, Object?>`). */
export type JsonObject = { [key: string]: unknown };

/** Dart's FormatException: input that does not have the expected shape. */
export class FormatException extends Error {
  constructor(message: string) {
    super(message);
    this.name = "FormatException";
  }
}

export function isJsonObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

type Guard<T> = { test: (value: unknown) => value is T; name: string };

const stringGuard: Guard<string> = { test: (value): value is string => typeof value === "string", name: "a string" };
const boolGuard: Guard<boolean> = { test: (value): value is boolean => typeof value === "boolean", name: "a boolean" };
const intGuard: Guard<number> = { test: (value): value is number => Number.isInteger(value), name: "an integer" };
const numberGuard: Guard<number> = {
  test: (value): value is number => typeof value === "number" && Number.isFinite(value),
  name: "a number",
};
const objectGuard: Guard<JsonObject> = { test: isJsonObject, name: "an object" };
const listGuard: Guard<unknown[]> = { test: (value): value is unknown[] => Array.isArray(value), name: "an array" };

function field<T>(json: JsonObject, key: string, guard: Guard<T>): T {
  const value = json[key];
  if (guard.test(value)) return value;
  throw new FormatException(`"${key}": expected ${guard.name}, got ${describeJson(value)}`);
}

function optField<T>(json: JsonObject, key: string, guard: Guard<T>): T | undefined {
  const value = json[key];
  if (value === undefined || value === null) return undefined;
  if (guard.test(value)) return value;
  throw new FormatException(`"${key}": expected ${guard.name} or nothing, got ${describeJson(value)}`);
}

function elements<T>(key: string, values: unknown[], guard: Guard<T>): T[] {
  return values.map((value, index) => {
    if (guard.test(value)) return value;
    throw new FormatException(`"${key}[${index}]": expected ${guard.name}, got ${describeJson(value)}`);
  });
}

export const string = (json: JsonObject, key: string): string => field(json, key, stringGuard);
export const optString = (json: JsonObject, key: string): string | undefined => optField(json, key, stringGuard);
export const boolean = (json: JsonObject, key: string): boolean => field(json, key, boolGuard);
export const optBool = (json: JsonObject, key: string): boolean | undefined => optField(json, key, boolGuard);
export const integer = (json: JsonObject, key: string): number => field(json, key, intGuard);
export const optInt = (json: JsonObject, key: string): number | undefined => optField(json, key, intGuard);
export const number = (json: JsonObject, key: string): number => field(json, key, numberGuard);
export const optNumber = (json: JsonObject, key: string): number | undefined => optField(json, key, numberGuard);
export const object = (json: JsonObject, key: string): JsonObject => field(json, key, objectGuard);
export const optObject = (json: JsonObject, key: string): JsonObject | undefined => optField(json, key, objectGuard);
export const list = (json: JsonObject, key: string): unknown[] => field(json, key, listGuard);
export const optList = (json: JsonObject, key: string): unknown[] | undefined => optField(json, key, listGuard);

export const strings = (json: JsonObject, key: string): string[] => elements(key, list(json, key), stringGuard);

export function optStrings(json: JsonObject, key: string): string[] | undefined {
  const values = optList(json, key);
  return values === undefined ? undefined : elements(key, values, stringGuard);
}

export const integers = (json: JsonObject, key: string): number[] => elements(key, list(json, key), intGuard);

export const objects = (json: JsonObject, key: string): JsonObject[] => elements(key, list(json, key), objectGuard);

export function optObjects(json: JsonObject, key: string): JsonObject[] | undefined {
  const values = optList(json, key);
  return values === undefined ? undefined : elements(key, values, objectGuard);
}

/** Milliseconds, rounded to whole microseconds as Dart's Duration keeps them; omp sends plain, possibly fractional, numbers. */
export function optMilliseconds(json: JsonObject, key: string): number | undefined {
  const value = optNumber(json, key);
  return value === undefined ? undefined : Math.round(value * 1000) / 1000;
}

/** The value of [values] named [name], or a FormatException. */
export function enumByName<T extends string>(values: readonly T[], name: string): T {
  const value = values.find((candidate) => candidate === name);
  if (value === undefined) throw new FormatException(`unknown value "${name}"; expected one of ${values.join(", ")}`);
  return value;
}

/** [value] as a JSON object, or a FormatException naming [what]. */
export function asJsonObject(value: unknown, what: string): JsonObject {
  if (isJsonObject(value)) return value;
  throw new FormatException(`${what}: expected a JSON object, got ${describeJson(value)}`);
}

export function describeJson(value: unknown): string {
  if (value === null || value === undefined) return "nothing";
  if (typeof value === "string") return "a string";
  if (typeof value === "boolean") return "a boolean";
  if (typeof value === "number") return "a number";
  if (Array.isArray(value)) return "an array";
  if (typeof value === "object") return "an object";
  return typeof value;
}
