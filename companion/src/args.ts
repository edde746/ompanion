import { type CallRequest, VerbError } from "./protocol.ts";

/** A `/ompx` argument that is not a valid call; `callId` is kept when it could be read. */
export class CallParseError extends Error {
	constructor(
		readonly callId: string | null,
		message: string,
	) {
		super(message);
	}
}

/** The companion's one record guard; fields stay `unknown` and are checked where they are read. */
export function isRecord(value: unknown): value is Record<string, unknown> {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Parses the `/ompx` argument: one line of JSON `{callId, verb, args}`. */
export function parseCall(text: string): CallRequest {
	let parsed: unknown;
	try {
		parsed = JSON.parse(text);
	} catch {
		throw new CallParseError(null, "the /ompx argument is not JSON");
	}
	if (!isRecord(parsed)) throw new CallParseError(null, "the /ompx argument is not a JSON object");
	const { callId, verb, args } = parsed;
	if (typeof callId !== "string" || callId === "") throw new CallParseError(null, "callId must be a non-empty string");
	if (typeof verb !== "string" || verb === "") throw new CallParseError(callId, "verb must be a non-empty string");
	if (!isRecord(args)) throw new CallParseError(callId, "args must be an object");
	const extra = Object.keys(parsed).filter(key => key !== "callId" && key !== "verb" && key !== "args");
	if (extra.length > 0) throw new CallParseError(callId, `unknown call fields: ${extra.join(", ")}`);
	return { callId, verb, args };
}

/** Rejects keys outside `allowed`, so a misspelt argument fails instead of being ignored. */
export function expectKeys(args: Record<string, unknown>, allowed: readonly string[]): void {
	const unknown = Object.keys(args).filter(key => !allowed.includes(key));
	if (unknown.length > 0) throw new VerbError("bad_request", `unknown arguments: ${unknown.join(", ")}`);
}

export function requireString(args: Record<string, unknown>, key: string): string {
	const value = args[key];
	if (typeof value !== "string" || value === "") throw new VerbError("bad_request", `${key} must be a non-empty string`);
	return value;
}

export function requireBoolean(args: Record<string, unknown>, key: string): boolean {
	const value = args[key];
	if (typeof value !== "boolean") throw new VerbError("bad_request", `${key} must be a boolean`);
	return value;
}

/** `undefined` when absent; otherwise the same rule as {@link requireString}. */
export function optionalString(args: Record<string, unknown>, key: string): string | undefined {
	return args[key] === undefined ? undefined : requireString(args, key);
}

export function optionalBoolean(args: Record<string, unknown>, key: string): boolean | undefined {
	return args[key] === undefined ? undefined : requireBoolean(args, key);
}

export function optionalInteger(
	args: Record<string, unknown>,
	key: string,
	min: number,
	max: number,
): number | undefined {
	const value = args[key];
	if (value === undefined) return undefined;
	if (typeof value !== "number" || !Number.isInteger(value) || value < min || value > max) {
		throw new VerbError("bad_request", `${key} must be an integer from ${min} to ${max}`);
	}
	return value;
}

export function requireOneOf<const T extends string>(
	args: Record<string, unknown>,
	key: string,
	values: readonly T[],
): T {
	const value = args[key];
	const match = values.find(candidate => candidate === value);
	if (match === undefined) throw new VerbError("bad_request", `${key} must be one of ${values.join(", ")}`);
	return match;
}

/** A non-empty string, or `null` meaning "clear". The key must be present. */
export function requireNullableString(args: Record<string, unknown>, key: string): string | null {
	if (args[key] === null) return null;
	if (!(key in args)) throw new VerbError("bad_request", `${key} is required (a string, or null to clear)`);
	return requireString(args, key);
}

export function optionalStringArray(args: Record<string, unknown>, key: string): string[] | undefined {
	const value = args[key];
	if (value === undefined) return undefined;
	if (!Array.isArray(value) || !value.every(item => typeof item === "string")) {
		throw new VerbError("bad_request", `${key} must be an array of strings`);
	}
	return value;
}
