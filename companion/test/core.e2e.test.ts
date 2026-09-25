import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { writeFile } from "node:fs/promises";
import * as path from "node:path";
import pkg from "../package.json" with { type: "json" };
import { OMP_VERSION, OmpDriver } from "./driver.ts";

setDefaultTimeout(60_000);

let omp: OmpDriver;

beforeAll(async () => {
	omp = await OmpDriver.start();
});

afterAll(async () => {
	await omp?.close();
});

interface SettingEntry {
	path: string;
	value?: unknown;
	provenance: string;
	redacted?: true;
}

async function readYaml(file: string): Promise<Record<string, unknown>> {
	const parsed: unknown = Bun.YAML.parse(await Bun.file(file).text());
	return (parsed ?? {}) as Record<string, unknown>;
}

const globalConfig = (): Promise<Record<string, unknown>> => readYaml(path.join(omp.home, ".omp", "agent", "config.yml"));

describe("calls", () => {
	test("hello names the companion, omp, the channel, every verb and event", async () => {
		const hello = (await omp.call("hello")) as { verbs: string[]; events: string[] };
		expect(hello).toMatchObject({
			companion: { version: pkg.version },
			omp: { version: OMP_VERSION },
			channel: "output",
		});
		expect(hello.verbs).toEqual(
			expect.arrayContaining([
				"hello",
				"state.snapshot",
				"pause.set",
				"queue.get",
				"queue.pop",
				"queue.clear",
				"settings.schema",
				"settings.get",
				"settings.set",
				"settings.unset",
				"roles.get",
				"roles.set",
			]),
		);
		expect(hello.events).toEqual(
			expect.arrayContaining(["pause.changed", "queue.changed", "settings.changed", "roles.changed", "request.settled"]),
		);
	});

	test("ompx is an extension command, so the app can detect the companion", async () => {
		const response = await omp.command({ type: "get_available_commands" });
		const commands = (response.data as { commands: { name: string; source: string }[] }).commands;
		expect(commands.find(command => command.name === "ompx")).toMatchObject({ source: "extension" });
	});

	test("invalid calls get bad_request replies, never extension errors", async () => {
		expect(await omp.reply("no.such.verb")).toMatchObject({
			ok: false,
			error: { code: "bad_request", message: "unknown verb: no.such.verb" },
		});
		expect((await omp.callError("pause.set", { paused: "yes" })).code).toBe("bad_request");
		expect((await omp.callError("state.snapshot", { verbose: true })).message).toContain("verbose");

		const since = omp.mark();
		await omp.command({ type: "prompt", message: "/ompx {not json" });
		const reply = await omp.waitFor(frame => frame.type === "ompx" && frame.kind === "reply", { since });
		expect(reply).toEqual({
			type: "ompx",
			kind: "reply",
			callId: null,
			ok: false,
			error: { code: "bad_request", message: "the /ompx argument is not JSON" },
		});
		expect(omp.frames.some(frame => frame.type === "extension_error")).toBe(false);
	});

	test("state.snapshot starts idle", async () => {
		expect(await omp.call("state.snapshot")).toEqual({
			pause: { paused: false, pausedAt: null },
			queue: { steering: [], followUp: [], count: 0 },
			requests: [],
		});
	});
});

describe("settings", () => {
	test("schema follows omp's settings panel", async () => {
		const schema = (await omp.call("settings.schema")) as {
			tabs: string[];
			settings: ({ path: string; isCredential: boolean; ui?: Record<string, unknown> } & Record<string, unknown>)[];
			conditions: Record<string, boolean>;
		};
		expect(schema.tabs).toEqual([
			"appearance",
			"model",
			"interaction",
			"context",
			"memory",
			"files",
			"shell",
			"tools",
			"tasks",
			"providers",
		]);
		const byPath = new Map(schema.settings.map(setting => [setting.path, setting]));
		expect(byPath.get("ask.timeout")).toMatchObject({
			type: "number",
			default: 0,
			isCredential: false,
			ui: { tab: "interaction", group: "Notifications", label: "Ask Timeout" },
		});
		expect(byPath.get("symbolPreset")).toMatchObject({ type: "enum", enumValues: ["unicode", "nerd", "ascii"] });
		// Runtime choices: the theme list is resolved, the composer shapes are out of an extension's reach.
		const themes = byPath.get("theme.dark")?.ui?.options as { value: string }[];
		expect(themes.map(option => option.value)).toContain("titanium");
		expect(byPath.get("composer.shape")?.ui?.options).toBe("runtime");
		expect(byPath.get("mnemopi.llmApiKey")).toMatchObject({ isCredential: true, ui: { condition: "mnemopiActive" } });
		// Config-file-only settings are listed too, without ui.
		expect(byPath.get("modelRoles")).toMatchObject({ type: "record" });
		expect(byPath.get("modelRoles")?.ui).toBeUndefined();
		expect(schema.conditions).toMatchObject({ vimModeEnabled: false, mnemopiActive: false });
	});

	test("a global write is on disk when the reply arrives, and is pushed", async () => {
		const since = omp.mark();
		expect(await omp.call("settings.set", { path: "ask.timeout", value: 30, scope: "global" })).toEqual({
			path: "ask.timeout",
			value: 30,
			provenance: "global",
		});
		expect((await globalConfig()).ask).toEqual({ timeout: 30 });
		const event = await omp.waitEvent("settings.changed", { since });
		expect((event.data as { settings: SettingEntry[] }).settings).toContainEqual({
			path: "ask.timeout",
			value: 30,
			provenance: "global",
		});
		expect(await omp.call("settings.get", { paths: ["ask.timeout", "theme.dark"] })).toMatchObject({
			settings: [
				{ path: "ask.timeout", value: 30, provenance: "global" },
				{ path: "theme.dark", value: "titanium", provenance: "default" },
			],
		});
	});

	test("an override is session-only and wins until cleared; unset falls back to the default", async () => {
		expect(await omp.call("settings.set", { path: "ask.timeout", value: 60, scope: "override" })).toEqual({
			path: "ask.timeout",
			value: 60,
			provenance: "runtime",
		});
		expect((await globalConfig()).ask).toEqual({ timeout: 30 });
		expect(await omp.call("settings.unset", { path: "ask.timeout", scope: "override" })).toEqual({
			path: "ask.timeout",
			value: 30,
			provenance: "global",
		});
		expect(await omp.call("settings.unset", { path: "ask.timeout", scope: "global" })).toEqual({
			path: "ask.timeout",
			value: 0,
			provenance: "default",
		});
		expect((await globalConfig()).ask).toBeUndefined();
	});

	test("conditions are re-evaluated when the settings they read change", async () => {
		const since = omp.mark();
		await omp.call("settings.set", { path: "tui.vimMode", value: true, scope: "override" });
		const event = await omp.waitEvent("settings.changed", { since });
		expect((event.data as { conditions: Record<string, boolean> }).conditions.vimModeEnabled).toBe(true);
		await omp.call("settings.unset", { path: "tui.vimMode", scope: "override" });
	});

	test("invalid writes are refused", async () => {
		expect((await omp.callError("settings.set", { path: "ask.timeout", value: "soon", scope: "global" })).code).toBe(
			"bad_request",
		);
		expect((await omp.callError("settings.set", { path: "symbolPreset", value: "emoji", scope: "override" })).code).toBe(
			"bad_request",
		);
		expect((await omp.callError("settings.set", { path: "ask.timeout", value: 1, scope: "project" })).code).toBe(
			"bad_request",
		);
		expect((await omp.callError("settings.set", { path: "ask.timeout", scope: "global" })).code).toBe("bad_request");
		expect((await omp.callError("settings.get", { paths: ["no.such.setting"] })).code).toBe("not_found");
	});

	test("credentials arrive as a file that is deleted, and are never echoed", async () => {
		const secret = "sk-ompx-test-4f1c";
		expect(
			(await omp.callError("settings.set", { path: "mnemopi.llmApiKey", value: secret, scope: "global" })).message,
		).toContain("valueFile");

		const file = path.join(omp.cwd, "secret.json");
		await writeFile(file, JSON.stringify(secret), { mode: 0o600 });
		const since = omp.mark();
		expect(
			await omp.call("settings.set", { path: "mnemopi.llmApiKey", valueFile: file, scope: "global" }),
		).toEqual({ path: "mnemopi.llmApiKey", provenance: "global", redacted: true });
		expect(await Bun.file(file).exists()).toBe(false);
		expect((await globalConfig()).mnemopi).toEqual({ llmApiKey: secret });
		await omp.waitEvent("settings.changed", { since });
		expect(await omp.call("settings.get", { paths: ["mnemopi.llmApiKey"] })).toMatchObject({
			settings: [{ path: "mnemopi.llmApiKey", provenance: "global", redacted: true }],
		});
		expect(omp.frames.some(frame => JSON.stringify(frame).includes(secret))).toBe(false);

		await omp.call("settings.unset", { path: "mnemopi.llmApiKey", scope: "global" });
		expect((await globalConfig()).mnemopi).toBeUndefined();
	});
});

describe("model roles", () => {
	interface Role {
		role: string;
		model: string | null;
		provenance: string;
		global: string | null;
		project: string | null;
	}
	const role = (state: unknown, name: string): Role | undefined =>
		(state as { roles: Role[] }).roles.find(entry => entry.role === name);

	test("roles.get lists omp's roles with the layer each comes from", async () => {
		const state = await omp.call("roles.get");
		expect(state).toMatchObject({ storage: "global" });
		// `--model` pins the default role for this process only.
		expect(role(state, "default")).toMatchObject({ model: "fake/fake-1", provenance: "runtime", global: null });
		expect(role(state, "smol")).toMatchObject({ name: "Fast", tag: "SMOL", section: "chat", model: null });
		expect(role(state, "dictation")).toMatchObject({ section: "kind" });
	});

	test("global and project assignments persist and are pushed", async () => {
		let since = omp.mark();
		let state = await omp.call("roles.set", { role: "smol", model: "fake/fake-1", scope: "global" });
		expect(role(state, "smol")).toEqual(
			expect.objectContaining({ model: "fake/fake-1", provenance: "global", global: "fake/fake-1", project: null }),
		);
		expect((await globalConfig()).modelRoles).toEqual({ smol: "fake/fake-1" });
		const pushed = await omp.waitEvent("roles.changed", { since });
		expect(role(pushed.data, "smol")).toMatchObject({ model: "fake/fake-1" });

		state = await omp.call("roles.set", { role: "smol", model: "fake/fake-think", scope: "project" });
		expect(role(state, "smol")).toMatchObject({ model: "fake/fake-think", provenance: "project", project: "fake/fake-think" });
		expect((await readYaml(path.join(omp.cwd, ".omp", "config.yml"))).modelRoles).toEqual({ smol: "fake/fake-think" });

		state = await omp.call("roles.set", { role: "smol", model: null, scope: "project" });
		expect(role(state, "smol")).toMatchObject({ model: "fake/fake-1", provenance: "global" });

		since = omp.mark();
		state = await omp.call("roles.set", { role: "smol", model: null, scope: "global" });
		expect(role(state, "smol")).toMatchObject({ model: null, provenance: "default" });
		expect((await globalConfig()).modelRoles ?? {}).toEqual({});
		await omp.waitEvent("roles.changed", { since });
	});

	test("a missing model is refused rather than read as a clear", async () => {
		expect((await omp.callError("roles.set", { role: "smol", scope: "global" })).code).toBe("bad_request");
	});
});
