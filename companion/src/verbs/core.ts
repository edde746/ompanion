import { readFile, rm } from "node:fs/promises";
import { isAbsolute } from "node:path";
import { agentPauseGate } from "@oh-my-pi/pi-agent-core";
import type { AgentSession, Settings } from "@oh-my-pi/pi-coding-agent";
import { orderedSettings } from "@oh-my-pi/pi-coding-agent/config/all-settings";
import { getKnownRoleIds, getRoleInfo } from "@oh-my-pi/pi-coding-agent/config/model-roles";
import { cfgModelRoleStorage } from "@oh-my-pi/pi-coding-agent/config/model-settings";
import { type AnySetting, all, lookup } from "@oh-my-pi/pi-coding-agent/config/registry";
import { createSettingsHost } from "@oh-my-pi/pi-coding-agent/config/settings-ui";
import pkg from "../../package.json" with { type: "json" };
import {
	expectKeys,
	optionalStringArray,
	requireBoolean,
	requireNullableString,
	requireOneOf,
	requireString,
} from "../args.ts";
import { channel, emitEvent } from "../channel.ts";
import { VerbError, type VerbHandler, type VerbTable } from "../protocol.ts";

/** Events pushed by the core verbs' watchers and the channel. */
export const coreEvents = [
	"pause.changed",
	"queue.changed",
	"settings.changed",
	"roles.changed",
	"request.settled",
] as const;

/**
 * omp emits no event when a message is queued, and a run parked on the pause gate or inside a
 * silent tool emits nothing at all, so the queue is also polled while the session streams.
 */
const QUEUE_POLL_MS = 250;

/** Settings panel choices omp fills at runtime; only the theme lists are reachable from an extension. */
const THEME_SETTINGS: readonly string[] = ["theme.dark", "theme.light"];

function pauseState(): { paused: boolean; pausedAt: number | null } {
	return { paused: agentPauseGate.paused, pausedAt: agentPauseGate.pausedAt ?? null };
}

function queueState(session: AgentSession): { steering: string[]; followUp: string[]; count: number } {
	const queued = session.getQueuedMessages();
	return { steering: [...queued.steering], followUp: [...queued.followUp], count: session.queuedMessageCount };
}

let lastQueue = "";
let queuePoll: Timer | undefined;

/** Emits `queue.changed` when the queue differs from the last one pushed. */
function checkQueue(session: AgentSession): void {
	const state = queueState(session);
	const key = JSON.stringify(state);
	if (key === lastQueue) return;
	lastQueue = key;
	emitEvent("queue.changed", state);
}

/** The settings panel's order (omp's domain order), then anything registered outside it. */
function schemaOrder(): AnySetting[] {
	const ordered = orderedSettings();
	const listed = new Set(ordered);
	return [...ordered, ...all().filter(setting => !listed.has(setting))];
}

function requireSetting(path: string): AnySetting {
	const setting = lookup(path);
	if (!setting) throw new VerbError("not_found", `unknown setting: ${path}`);
	return setting;
}

/**
 * Value of the settings layers (the environment is left out, as in omp's settings panel) and the
 * layer that supplies the effective value. Replies land in the run directory's `out.jsonl`, so a
 * configured credential is never sent: it is reported as `redacted`.
 */
function settingValue(setting: AnySetting, settings: Settings): Record<string, unknown> {
	const value = setting.layered(settings);
	const provenance = setting.provenance(settings);
	if (setting.isCredential && value) return { path: setting.id, provenance, redacted: true };
	return { path: setting.id, value: value ?? null, provenance };
}

/** Current value of every visibility condition named by a settings row (`ui.condition`). */
function conditionValues(): Record<string, boolean> {
	const values: Record<string, boolean> = {};
	for (const entry of createSettingsHost().entries) {
		const name = entry.ui?.condition;
		if (name !== undefined && entry.condition) values[name] = entry.condition();
	}
	return values;
}

function settingSchema(setting: AnySetting, themes: readonly string[]): Record<string, unknown> {
	const { definition, ui } = setting;
	const schema: Record<string, unknown> = {
		path: setting.id,
		type: setting.type,
		default: setting.isCredential && setting.default ? null : (setting.default ?? null),
		isCredential: setting.isCredential,
	};
	if (setting.enumValues) schema.enumValues = [...setting.enumValues];
	if (definition.type === "array" && definition.items) {
		schema.items = { values: [...definition.items.values], label: definition.items.label };
	}
	if (definition.pathScoped) schema.pathScoped = { valuesKey: definition.pathScoped.valuesKey };
	if (setting.envName) schema.env = { name: setting.envName, fallback: setting.envFallback };
	if (ui) {
		const options =
			ui.options === "runtime" && THEME_SETTINGS.includes(setting.id)
				? themes.map(theme => ({ value: theme, label: theme }))
				: ui.options;
		schema.ui = {
			tab: ui.tab,
			...(ui.group === undefined ? {} : { group: ui.group }),
			label: ui.label,
			description: ui.description,
			...(ui.warning === undefined ? {} : { warning: ui.warning }),
			...(ui.condition === undefined ? {} : { condition: ui.condition }),
			...(options === undefined ? {} : { options }),
			...(ui.secret === undefined ? {} : { secret: ui.secret }),
			...(ui.ordered === undefined ? {} : { ordered: ui.ordered }),
		};
	}
	return schema;
}

function rolesState(settings: Settings): Record<string, unknown> {
	return {
		storage: cfgModelRoleStorage.get(settings),
		roles: getKnownRoleIds(settings).map(role => {
			const info = getRoleInfo(role, settings);
			return {
				role,
				name: info.name,
				tag: info.tag ?? null,
				section: info.section,
				model: settings.getModelRole(role) ?? null,
				provenance: settings.getModelRoleProvenance(role),
				global: settings.getGlobalModelRole(role) ?? null,
				project: settings.getProjectModelRole(role) ?? null,
			};
		}),
	};
}

/**
 * `value` travels through `in.jsonl` on the host, so credentials must come as `valueFile`: a host
 * file holding the JSON value, deleted as soon as it is read (docs/PLAN.md §5, secrets).
 */
async function incomingValue(args: Record<string, unknown>, setting: AnySetting): Promise<unknown> {
	if ("value" in args === "valueFile" in args) {
		throw new VerbError("bad_request", "exactly one of value and valueFile is required");
	}
	if ("value" in args) {
		if (setting.isCredential) throw new VerbError("bad_request", `${setting.id} is a credential: send it as valueFile`);
		return args.value;
	}
	const file = requireString(args, "valueFile");
	if (!isAbsolute(file)) throw new VerbError("bad_request", "valueFile must be an absolute path");
	let text: string;
	try {
		text = await readFile(file, "utf8");
	} finally {
		await rm(file, { force: true });
	}
	try {
		return JSON.parse(text);
	} catch {
		throw new VerbError("bad_request", "valueFile does not hold a JSON value");
	}
}

function applySetting(write: () => void): void {
	try {
		write();
	} catch (error) {
		// Setting.set/override only throw on validation (registry.ts assertWritable).
		throw new VerbError("bad_request", error instanceof Error ? error.message : String(error));
	}
}

/** `hello` needs the merged verb table, which only the dispatcher knows. */
export function helloVerb(verbNames: () => readonly string[], events: readonly string[]): VerbHandler {
	return async (args, { pi }) => {
		expectKeys(args, []);
		return {
			companion: { version: pkg.version },
			omp: { version: pi.pi.VERSION },
			channel: channel().kind,
			verbs: [...verbNames()].sort(),
			events: [...events].sort(),
		};
	};
}

export const coreVerbs: VerbTable = {
	"state.snapshot": async (args, { session }) => {
		expectKeys(args, []);
		return { pause: pauseState(), queue: queueState(session), requests: channel().openRequests() };
	},

	"pause.set": async args => {
		expectKeys(args, ["paused"]);
		if (requireBoolean(args, "paused")) agentPauseGate.pause();
		else agentPauseGate.resume();
		return pauseState();
	},

	"queue.get": async (args, { session }) => {
		expectKeys(args, []);
		return queueState(session);
	},

	"queue.pop": async (args, { session }) => {
		expectKeys(args, []);
		const message = session.popLastQueuedMessage();
		checkQueue(session);
		return message ?? null;
	},

	"queue.clear": async (args, { session }) => {
		expectKeys(args, []);
		const cleared = session.clearQueue();
		checkQueue(session);
		return cleared;
	},

	"settings.schema": async (args, { pi }) => {
		expectKeys(args, []);
		const themes = await pi.pi.getAvailableThemes();
		const tabs = [...new Set(createSettingsHost().entries.map(entry => entry.ui?.tab))];
		return {
			tabs: tabs.filter(tab => tab !== undefined),
			settings: schemaOrder().map(setting => settingSchema(setting, themes)),
			conditions: conditionValues(),
		};
	},

	"settings.get": async (args, { session }) => {
		expectKeys(args, ["paths"]);
		const paths = optionalStringArray(args, "paths");
		const settings = paths ? paths.map(requireSetting) : schemaOrder();
		return {
			settings: settings.map(setting => settingValue(setting, session.settings)),
			conditions: conditionValues(),
		};
	},

	"settings.set": async (args, { session }) => {
		expectKeys(args, ["path", "value", "valueFile", "scope"]);
		const setting = requireSetting(requireString(args, "path"));
		const scope = requireOneOf(args, "scope", ["global", "override"]);
		const value = await incomingValue(args, setting);
		applySetting(() =>
			scope === "global" ? setting.set(session.settings, value) : setting.override(session.settings, value),
		);
		// Global writes are saved in the background; the reply promises they are on disk.
		if (scope === "global") await session.settings.flush();
		return settingValue(setting, session.settings);
	},

	"settings.unset": async (args, { session }) => {
		expectKeys(args, ["path", "scope"]);
		const setting = requireSetting(requireString(args, "path"));
		if (requireOneOf(args, "scope", ["global", "override"]) === "global") {
			setting.unset(session.settings);
			await session.settings.flush();
		} else {
			setting.clearOverride(session.settings);
		}
		return settingValue(setting, session.settings);
	},

	"roles.get": async (args, { session }) => {
		expectKeys(args, []);
		return rolesState(session.settings);
	},

	"roles.set": async (args, { session }) => {
		expectKeys(args, ["role", "model", "scope"]);
		const role = requireString(args, "role");
		const model = requireNullableString(args, "model");
		const scope = requireOneOf(args, "scope", ["global", "project"]);
		const { settings } = session;
		if (scope === "global") settings.setModelRole(role, model ?? undefined);
		else if (model === null) settings.clearProjectModelRole(role);
		else settings.setProjectModelRole(role, model);
		await settings.flush();
		return rolesState(settings);
	},
};

/**
 * Subscribes the push sources of the core verbs. Called once per process, after the channel is
 * bound to the main session.
 */
export function watchCore(session: AgentSession): void {
	agentPauseGate.onChange(() => emitEvent("pause.changed", pauseState()));

	lastQueue = JSON.stringify(queueState(session));
	session.subscribe(() => {
		checkQueue(session);
		if (!session.isStreaming || queuePoll) return;
		queuePoll = setInterval(() => {
			checkQueue(session);
			if (session.isStreaming) return;
			clearInterval(queuePoll);
			queuePoll = undefined;
		}, QUEUE_POLL_MS);
		queuePoll.unref();
	});

	const settings = session.settings;
	const changed = new Set<AnySetting>();
	settings.onEffectiveChange(all(), setting => {
		// Coalesced per microtask: a reload from disk changes many settings at once.
		if (changed.size === 0) {
			queueMicrotask(() => {
				const batch = [...changed];
				changed.clear();
				emitEvent("settings.changed", {
					settings: batch.map(item => settingValue(item, settings)),
					conditions: conditionValues(),
				});
				if (batch.some(item => item.id === "modelRoles")) emitEvent("roles.changed", rolesState(settings));
			});
		}
		changed.add(setting);
	});
}
