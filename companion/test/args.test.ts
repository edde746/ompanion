import { describe, expect, test } from "bun:test";
import {
	CallParseError,
	expectKeys,
	optionalInteger,
	optionalStringArray,
	parseCall,
	requireNullableString,
	requireOneOf,
} from "../src/args.ts";
import { VerbError } from "../src/protocol.ts";

function parseError(text: string): CallParseError {
	try {
		parseCall(text);
	} catch (error) {
		if (error instanceof CallParseError) return error;
		throw error;
	}
	throw new Error(`parseCall accepted ${text}`);
}

function verbError(run: () => unknown): VerbError {
	try {
		run();
	} catch (error) {
		if (error instanceof VerbError) return error;
		throw error;
	}
	throw new Error("expected a VerbError");
}

describe("parseCall", () => {
	test("accepts {callId, verb, args}", () => {
		expect(parseCall(' {"callId":"phone:7","verb":"pause.set","args":{"paused":true}} ')).toEqual({
			callId: "phone:7",
			verb: "pause.set",
			args: { paused: true },
		});
	});

	test("an unreadable call has no callId to answer", () => {
		expect(parseError("pause.set {}").callId).toBeNull();
		expect(parseError("[1,2]").callId).toBeNull();
		expect(parseError('{"verb":"hello","args":{}}').callId).toBeNull();
		expect(parseError('{"callId":"","verb":"hello","args":{}}').callId).toBeNull();
	});

	test("a readable callId is kept so the error reply reaches the caller", () => {
		expect(parseError('{"callId":"a:1","args":{}}')).toMatchObject({ callId: "a:1" });
		expect(parseError('{"callId":"a:2","verb":"hello"}')).toMatchObject({ callId: "a:2" });
		expect(parseError('{"callId":"a:3","verb":"hello","args":[]}')).toMatchObject({ callId: "a:3" });
		expect(parseError('{"callId":"a:4","verb":"hello","args":{},"extra":1}').message).toContain("extra");
	});
});

describe("argument validation", () => {
	test("unknown argument names are rejected", () => {
		expect(() => expectKeys({ paused: true }, ["paused"])).not.toThrow();
		const error = verbError(() => expectKeys({ pasued: true }, ["paused"]));
		expect(error.code).toBe("bad_request");
		expect(error.message).toContain("pasued");
	});

	test("requireOneOf returns the matching literal", () => {
		expect(requireOneOf({ scope: "override" }, "scope", ["global", "override"])).toBe("override");
		expect(verbError(() => requireOneOf({ scope: "project" }, "scope", ["global", "override"])).code).toBe(
			"bad_request",
		);
		expect(verbError(() => requireOneOf({}, "scope", ["global"])).code).toBe("bad_request");
	});

	test("requireNullableString distinguishes clear from missing", () => {
		expect(requireNullableString({ model: null }, "model")).toBeNull();
		expect(requireNullableString({ model: "fake/fake-1" }, "model")).toBe("fake/fake-1");
		expect(verbError(() => requireNullableString({}, "model")).message).toContain("required");
		expect(verbError(() => requireNullableString({ model: "" }, "model")).code).toBe("bad_request");
	});

	test("optionalStringArray", () => {
		expect(optionalStringArray({}, "paths")).toBeUndefined();
		expect(optionalStringArray({ paths: ["a", "b"] }, "paths")).toEqual(["a", "b"]);
		expect(verbError(() => optionalStringArray({ paths: ["a", 1] }, "paths")).code).toBe("bad_request");
		expect(verbError(() => optionalStringArray({ paths: "a" }, "paths")).code).toBe("bad_request");
	});

	test("optionalInteger enforces its inclusive range", () => {
		expect(optionalInteger({}, "limit", 1, 10)).toBeUndefined();
		expect(optionalInteger({ limit: 1 }, "limit", 1, 10)).toBe(1);
		expect(optionalInteger({ limit: 10 }, "limit", 1, 10)).toBe(10);
		for (const limit of [0, 11, 2.5, "3"]) {
			expect(verbError(() => optionalInteger({ limit }, "limit", 1, 10)).message).toBe(
				"limit must be an integer from 1 to 10",
			);
		}
	});
});
