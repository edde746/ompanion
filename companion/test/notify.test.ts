import { describe, expect, test } from "bun:test";
import {
	doneBody,
	type Notification,
	parseRegistration,
	payloadJson,
	type Registration,
	seal,
	sessionTitle,
} from "../src/notify.ts";

/** docs/contracts/push.md, "Test vector". */
const VECTOR = {
	key: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",
	nonce: "oKGio6Slpqeoqaqr",
	deviceId: "00112233445566778899aabbccddeeff",
	ciphertext:
		"nToKD3/6Lp0JDOm3JUDiuh/CPDK+lS8N/2ZP6BriESPoVCrOjQ5xTyryTawrQKGLdjlqahG1aQ0oMWUOxQTtko6eqgdfyIHPgc3Rd+K+49uqbsXQ6rL8CZ0cUfTCtTW7vttKhWnd4PXy+Spy8eGZREFyW4yYXOMcW6e7hMQ0gD6gY5JT8TH1dUMwiud3aKv07LzbCdGo2k5K7fmawaIWB+R6cNXPSHo0w2ZHAhu3xZUEBo35cRWAHK6gAkp+uC5gDQZ8+VDhi93DbXCyNzdjdu8yZsnjEAE6Fz78cw==",
	plaintext:
		'{"v":1,"kind":"done","machineId":"m1","runId":"r1","sessionPath":"/home/u/.omp/agent/sessions/x/1_a.jsonl","title":"Fix the parser","subtitle":"devbox · Done","body":"All tests pass.","ts":1790000000000}',
};

const done: Notification = {
	kind: "done",
	runId: "r1",
	sessionPath: "/home/u/.omp/agent/sessions/x/1_a.jsonl",
	title: "Fix the parser",
	body: "All tests pass.",
	ts: 1_790_000_000_000,
};

function bytes(base64: string): Uint8Array<ArrayBuffer> {
	return new Uint8Array(Buffer.from(base64, "base64"));
}

interface Payload {
	title: string;
	subtitle: string;
	body: string;
}

function payload(notification: Notification, machineId = "m1", machineName = "devbox"): Payload {
	return JSON.parse(payloadJson(notification, machineId, machineName)) as Payload;
}

describe("payload", () => {
	test("the contract's test vector: same plaintext, same ciphertext", async () => {
		const plaintext = payloadJson(done, "m1", "devbox");
		expect(plaintext).toBe(VECTOR.plaintext);
		const sealed = await seal(bytes(VECTOR.key), bytes(VECTOR.nonce), VECTOR.deviceId, plaintext);
		expect(Buffer.from(sealed).toString("base64")).toBe(VECTOR.ciphertext);
	});

	test("the subtitle names the machine and the kind", () => {
		expect(payload({ ...done, kind: "input" }).subtitle).toBe("devbox · Needs input");
		expect(payload({ ...done, kind: "failed" }).subtitle).toBe("devbox · Failed");
		expect(payload({ ...done, kind: "test" }, "m1", "Work Mac").subtitle).toBe("Work Mac · Test");
	});

	test("title and body are cut at 120 and 240 characters, the last one an ellipsis", () => {
		const cut = payload({ ...done, title: "t".repeat(121), body: "b".repeat(241) });
		expect(cut.title).toBe(`${"t".repeat(119)}…`);
		expect(cut.body).toBe(`${"b".repeat(239)}…`);
		const exact = payload({ ...done, title: "t".repeat(120), body: "b".repeat(240) });
		expect(exact.title).toBe("t".repeat(120));
		expect(exact.body).toBe("b".repeat(240));
	});

	test("a cut never splits a character", () => {
		const family = "👨‍👩‍👧";
		const { body } = payload({ ...done, body: `${"x".repeat(238)}${family.repeat(3)}` });
		expect(body).toBe(`${"x".repeat(238)}${family}…`);
	});

	test("the plaintext stays within 1,536 bytes, shortening the body before the title", () => {
		const wide = "字";
		const long: Notification = {
			...done,
			sessionPath: `/${"p".repeat(700)}.jsonl`,
			title: wide.repeat(120),
			body: wide.repeat(240),
		};
		const json = payloadJson(long, "m1", "devbox");
		expect(Buffer.byteLength(json)).toBeLessThanOrEqual(1536);
		const { title, body } = JSON.parse(json) as Payload;
		expect(title).toBe(wide.repeat(120));
		expect(body.endsWith("…")).toBe(true);
		expect(body.length).toBeLessThan(240);
		// Only as much as needed: one more character would not fit.
		expect(Buffer.byteLength(json) + Buffer.byteLength(wide)).toBeGreaterThan(1536);
	});

	test("emoji that fill the cap are dropped whole", () => {
		const family = "👨‍👩‍👧";
		const json = payloadJson({ ...done, body: family.repeat(240) }, "m1", "devbox");
		expect(Buffer.byteLength(json)).toBeLessThanOrEqual(1536);
		const { body } = JSON.parse(json) as Payload;
		expect(body.replaceAll(family, "")).toBe("…");
	});

	test("ids too long for any payload fail loudly", () => {
		expect(() => payloadJson(done, "m".repeat(1600), "devbox")).toThrow("does not fit 1536 bytes");
	});
});

const deviceId = "0123456789abcdef0123456789abcdef";
const registration: Registration = {
	v: 1,
	deviceId,
	machineId: "m1",
	machineName: "devbox",
	platform: "android",
	fid: "fid-of-the-phone",
	key: VECTOR.key,
	kinds: ["done", "input"],
	relay: "https://push.ompanion.app/v1/send",
};
const file = `${deviceId}.json`;

function parse(value: unknown, name = file) {
	return () => parseRegistration(name, JSON.stringify(value));
}

describe("registration", () => {
	test("a file of the contract's shape parses", () => {
		expect(parseRegistration(file, JSON.stringify(registration))).toEqual(registration);
	});

	test("a file named after another device is refused", () => {
		expect(parse(registration, "ffffffffffffffffffffffffffffffff.json")).toThrow("not named");
	});

	test("missing, unknown and mistyped fields are refused", () => {
		const { relay: _relay, ...noRelay } = registration;
		expect(parse(noRelay)).toThrow("missing relay");
		expect(parse({ ...registration, extra: true })).toThrow("unknown key extra");
		expect(parse({ ...registration, v: 2 })).toThrow("v is 2");
		const upper = deviceId.toUpperCase();
		expect(parse({ ...registration, deviceId: upper }, `${upper}.json`)).toThrow("deviceId");
		expect(parse({ ...registration, machineName: "" })).toThrow("machineName");
		expect(parse({ ...registration, platform: "windows" })).toThrow("platform");
		expect(parse({ ...registration, fid: "f".repeat(257) })).toThrow("fid");
		expect(parse({ ...registration, fid: "" })).toThrow("fid");
		const { fid: _fid, ...legacy } = registration;
		expect(parse({ ...legacy, token: "fcm-token" })).toThrow("missing fid");
		expect(() => parseRegistration(file, "{")).toThrow("not valid JSON");
	});

	test("the key must be the base64 of 32 bytes", () => {
		expect(parse({ ...registration, key: Buffer.alloc(16).toString("base64") })).toThrow("key");
		expect(parse({ ...registration, key: VECTOR.key.replace("=", "") })).toThrow("key");
	});

	test("kinds are distinct members of input, done and failed", () => {
		expect(parseRegistration(file, JSON.stringify({ ...registration, kinds: [] })).kinds).toEqual([]);
		expect(parse({ ...registration, kinds: ["done", "test"] })).toThrow("kinds");
		expect(parse({ ...registration, kinds: ["done", "done"] })).toThrow("kinds");
		expect(parse({ ...registration, kinds: "done" })).toThrow("kinds");
	});

	test("the relay is an http(s) URL", () => {
		const local = "http://127.0.0.1:8080/v1/send";
		expect(parseRegistration(file, JSON.stringify({ ...registration, relay: local })).relay).toBe(local);
		expect(parse({ ...registration, relay: "file:///etc/passwd" })).toThrow("relay");
		expect(parse({ ...registration, relay: "push.ompanion.app" })).toThrow("relay");
	});
});

describe("texts", () => {
	test("the title is the session's name, else its first user line, else its directory", () => {
		expect(sessionTitle("Parser work", "fix it", "/home/u/proj")).toBe("Parser work");
		expect(sessionTitle(undefined, "\n  Fix the parser  \nthen test", "/home/u/proj")).toBe("Fix the parser");
		expect(sessionTitle(undefined, undefined, "/home/u/proj")).toBe("proj");
		expect(sessionTitle(undefined, "   ", "/")).toBe("/");
	});

	test("done says the first non-empty line of the last answer, else Finished", () => {
		const answer = (text: string) =>
			({ role: "assistant", content: [{ type: "text", text }], stopReason: "stop" }) as Parameters<typeof doneBody>[0];
		expect(doneBody(answer("\n\nAll tests pass.\nDetails follow"))).toBe("All tests pass.");
		expect(doneBody(answer("  \n"))).toBe("Finished");
		expect(doneBody(undefined)).toBe("Finished");
	});
});
