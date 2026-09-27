import { readdir, readFile, rm } from "node:fs/promises";
import { homedir } from "node:os";
import * as path from "node:path";
import type { AgentMessage } from "@oh-my-pi/pi-agent-core";
import type { AssistantMessage } from "@oh-my-pi/pi-ai";
import type { AgentSession, ExtensionUIContext, ExtensionUISelectItem, SessionEntry } from "@oh-my-pi/pi-coding-agent";
import { isEnoent } from "@oh-my-pi/pi-utils";
import { expectKeys, isRecord } from "./args.ts";
import { channel } from "./channel.ts";
import type { IdleRun } from "./idle.ts";
import { VerbError, type VerbTable } from "./protocol.ts";

/**
 * Push notifications to phones: every detached run encrypts a message for each registered phone and posts it to the
 * relay. Wire contract: docs/contracts/push.md.
 */

export type Kind = "input" | "done" | "failed";
type PayloadKind = Kind | "test";

const KINDS: readonly Kind[] = ["input", "done", "failed"];
const LABELS: Readonly<Record<PayloadKind, string>> = {
	input: "Needs input",
	done: "Done",
	failed: "Failed",
	test: "Test",
};
const REGISTRATION_KEYS = ["v", "deviceId", "machineId", "machineName", "platform", "fid", "key", "kinds", "relay"];
const DEVICE_ID = /^[0-9a-f]{32}$/;
/** Standard base64 with padding of exactly 32 bytes. */
const KEY_BASE64 = /^[A-Za-z0-9+/]{43}=$/;
/** The relay's own limit on `fid` (a longer one is its `400`). */
const MAX_FID_LENGTH = 256;
const MAX_PAYLOAD_BYTES = 1536;
const MAX_TITLE = 120;
const MAX_BODY = 240;
const RELAY_TIMEOUT_MS = 10_000;

/** A phone's `<home>/.ompanion/push/<deviceId>.json`. */
export interface Registration {
	v: 1;
	deviceId: string;
	machineId: string;
	machineName: string;
	platform: "android" | "ios";
	fid: string;
	key: string;
	kinds: Kind[];
	relay: string;
}

/** What one notification says, before the per-device `machineId` and `subtitle`. */
export interface Notification {
	kind: PayloadKind;
	runId: string | null;
	sessionPath: string | null;
	title: string;
	body: string;
	ts: number;
}

interface Entry {
	file: string;
	/** The bytes read, so a `410` deletes the file only when the phone has not rewritten it since. */
	bytes: Buffer;
	registration: Registration;
}

type Outcome = { ok: true } | { ok: false; gone: boolean; message: string };

function errorText(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

function nonEmptyString(value: unknown): value is string {
	return typeof value === "string" && value !== "";
}

/**
 * Parses a registration file named `name`.
 *
 * @throws Error naming what does not match the contract's shape.
 */
export function parseRegistration(name: string, text: string): Registration {
	let value: unknown;
	try {
		value = JSON.parse(text);
	} catch {
		throw new Error("not valid JSON");
	}
	if (!isRecord(value)) throw new Error("not a JSON object");
	const keys = Object.keys(value);
	const missing = REGISTRATION_KEYS.filter(key => !keys.includes(key));
	if (missing.length > 0) throw new Error(`missing ${missing.join(", ")}`);
	const unknown = keys.filter(key => !REGISTRATION_KEYS.includes(key));
	if (unknown.length > 0) throw new Error(`unknown key ${unknown.join(", ")}`);
	const { v, deviceId, machineId, machineName, platform, fid, key, kinds, relay } = value;
	if (v !== 1) throw new Error(`v is ${JSON.stringify(v)}, not 1`);
	if (typeof deviceId !== "string" || !DEVICE_ID.test(deviceId)) {
		throw new Error("deviceId is not 32 lowercase hex digits");
	}
	if (name !== `${deviceId}.json`) throw new Error(`the file is not named ${deviceId}.json`);
	if (!nonEmptyString(machineId)) throw new Error("machineId is not a non-empty string");
	if (!nonEmptyString(machineName)) throw new Error("machineName is not a non-empty string");
	if (platform !== "android" && platform !== "ios") throw new Error('platform is not "android" or "ios"');
	if (!nonEmptyString(fid) || fid.length > MAX_FID_LENGTH) {
		throw new Error(`fid is not a string of 1 to ${MAX_FID_LENGTH} characters`);
	}
	if (typeof key !== "string" || !KEY_BASE64.test(key)) throw new Error("key is not the base64 of 32 bytes");
	if (
		!Array.isArray(kinds) ||
		!kinds.every((kind): kind is Kind => KINDS.includes(kind)) ||
		new Set(kinds).size !== kinds.length
	) {
		throw new Error(`kinds is not a list of distinct ${KINDS.join(", ")}`);
	}
	if (typeof relay !== "string" || !URL.canParse(relay) || !["https:", "http:"].includes(new URL(relay).protocol)) {
		throw new Error("relay is not an http(s) URL");
	}
	return { v, deviceId, machineId, machineName, platform, fid, key, kinds, relay };
}

const segmenter = new Intl.Segmenter();

/** At most `max` characters (grapheme clusters), the last one `…` when cut. */
function clip(characters: readonly string[], max: number): string {
	if (characters.length <= max) return characters.join("");
	return `${characters.slice(0, max - 1).join("").trimEnd()}…`;
}

/**
 * The plaintext for one device: `title` and `body` clipped to their limits, then shortened further one character at a
 * time, body first, until the JSON fits 1,536 bytes.
 *
 * @throws Error when even a one-character title and body do not fit (the ids or the machine name are that long).
 */
export function payloadJson(notification: Notification, machineId: string, machineName: string): string {
	const title = Array.from(segmenter.segment(notification.title), part => part.segment);
	const body = Array.from(segmenter.segment(notification.body), part => part.segment);
	const subtitle = `${machineName} · ${LABELS[notification.kind]}`;
	let titleMax = MAX_TITLE;
	let bodyMax = MAX_BODY;
	for (;;) {
		const json = JSON.stringify({
			v: 1,
			kind: notification.kind,
			machineId,
			runId: notification.runId,
			sessionPath: notification.sessionPath,
			title: clip(title, titleMax),
			subtitle,
			body: clip(body, bodyMax),
			ts: notification.ts,
		});
		if (Buffer.byteLength(json) <= MAX_PAYLOAD_BYTES) return json;
		if (bodyMax > 1 && body.length > 1) bodyMax = Math.min(bodyMax, body.length) - 1;
		else if (titleMax > 1 && title.length > 1) titleMax = Math.min(titleMax, title.length) - 1;
		else throw new Error(`a notification for ${machineName} does not fit ${MAX_PAYLOAD_BYTES} bytes`);
	}
}

/** AES-256-GCM with the UTF-8 `deviceId` as additional data: the ciphertext followed by the 16-byte tag. */
export async function seal(
	key: Uint8Array<ArrayBuffer>,
	nonce: Uint8Array<ArrayBuffer>,
	deviceId: string,
	plaintext: string,
): Promise<Uint8Array> {
	const encoder = new TextEncoder();
	const cryptoKey = await crypto.subtle.importKey("raw", key, "AES-GCM", false, ["encrypt"]);
	const sealed = await crypto.subtle.encrypt(
		{ name: "AES-GCM", iv: nonce, additionalData: encoder.encode(deviceId) },
		cryptoKey,
		encoder.encode(plaintext),
	);
	return new Uint8Array(sealed);
}

/** The session's name, else the first line of its first user message, else the last component of its cwd. */
export function sessionTitle(name: string | undefined, firstMessage: string | undefined, cwd: string): string {
	const line = firstMessage
		?.split("\n")
		.map(part => part.trim())
		.find(part => part !== "");
	return name?.trim() || line || path.basename(cwd) || cwd;
}

function messageText(message: AgentMessage): string | undefined {
	if (message.role !== "user" && message.role !== "assistant") return undefined;
	const content = message.content;
	if (typeof content === "string") return content;
	const texts: string[] = [];
	for (const part of content) if (part.type === "text") texts.push(part.text);
	return texts.join("\n");
}

function firstUserMessage(entries: readonly SessionEntry[]): string | undefined {
	for (const entry of entries) {
		if (entry.type === "message" && entry.message.role === "user") return messageText(entry.message);
	}
	return undefined;
}

/** The `done` body of a run whose last assistant message is `message`. */
export function doneBody(message: AgentMessage | undefined): string {
	const text = message ? messageText(message) : undefined;
	return (
		text
			?.split("\n")
			.map(line => line.trim())
			.find(line => line !== "") ?? "Finished"
	);
}

function pushDir(): string {
	return path.join(homedir(), ".ompanion", "push");
}

/** Warnings already shown in this process: `file:<name>` and `relay:<deviceId>`. */
const warned = new Set<string>();

function warnOnce(key: string, message: string): void {
	if (warned.has(key)) return;
	warned.add(key);
	channel().notify(message, "warning");
}

/** Every valid registration, read afresh; an invalid file is skipped with a warning once per process. */
async function readRegistrations(): Promise<Entry[]> {
	const dir = pushDir();
	let names: string[];
	try {
		names = await readdir(dir);
	} catch (error) {
		if (isEnoent(error)) return [];
		throw error;
	}
	const entries: Entry[] = [];
	for (const name of names.filter(candidate => candidate.endsWith(".json")).sort()) {
		const file = path.join(dir, name);
		let bytes: Buffer;
		let registration: Registration;
		try {
			bytes = await readFile(file);
			registration = parseRegistration(name, bytes.toString("utf8"));
		} catch (error) {
			// Deleted between the listing and the read: push was turned off.
			if (isEnoent(error)) continue;
			warnOnce(`file:${name}`, `Push notifications skip ${file}: ${errorText(error)}`);
			continue;
		}
		entries.push({ file, bytes, registration });
	}
	return entries;
}

/**
 * The calling device's registration for `notify.test`.
 *
 * @throws VerbError `not_found` when it has none, or an invalid one.
 */
async function readRegistration(deviceId: string): Promise<Entry> {
	if (!DEVICE_ID.test(deviceId)) throw new VerbError("not_found", `no push registration for device "${deviceId}"`);
	const name = `${deviceId}.json`;
	const file = path.join(pushDir(), name);
	let bytes: Buffer;
	try {
		bytes = await readFile(file);
	} catch (error) {
		if (isEnoent(error)) throw new VerbError("not_found", `no push registration for device ${deviceId}`);
		throw error;
	}
	try {
		return { file, bytes, registration: parseRegistration(name, bytes.toString("utf8")) };
	} catch (error) {
		throw new VerbError("not_found", `the push registration ${file} is invalid: ${errorText(error)}`);
	}
}

async function relayError(response: Response): Promise<string> {
	const text = await response.text();
	try {
		const parsed: unknown = JSON.parse(text);
		if (isRecord(parsed) && typeof parsed.error === "string") return parsed.error;
	} catch {
		// Not the relay's JSON (a proxy's error page): its text below says more than nothing.
	}
	return text.trim().slice(0, 200) || response.statusText;
}

async function post(registration: Registration, plaintext: string): Promise<Outcome> {
	const nonce = crypto.getRandomValues(new Uint8Array(12));
	const key = new Uint8Array(Buffer.from(registration.key, "base64"));
	const ciphertext = await seal(key, nonce, registration.deviceId, plaintext);
	try {
		const response = await fetch(registration.relay, {
			method: "POST",
			headers: { "Content-Type": "application/json" },
			body: JSON.stringify({
				fid: registration.fid,
				platform: registration.platform,
				nonce: Buffer.from(nonce).toString("base64"),
				ciphertext: Buffer.from(ciphertext).toString("base64"),
			}),
			signal: AbortSignal.timeout(RELAY_TIMEOUT_MS),
		});
		if (response.ok) {
			await response.body?.cancel();
			return { ok: true };
		}
		const message = `the relay answered ${response.status}: ${await relayError(response)}`;
		return { ok: false, gone: response.status === 410, message };
	} catch (error) {
		return { ok: false, gone: false, message: `the relay did not answer: ${errorText(error)}` };
	}
}

/** A `410`'s cleanup: the phone that rewrote its file meanwhile has registered again. */
async function deleteIfUnchanged(entry: Entry): Promise<void> {
	let current: Buffer;
	try {
		current = await readFile(entry.file);
	} catch (error) {
		if (isEnoent(error)) return;
		throw error;
	}
	if (current.equals(entry.bytes)) await rm(entry.file, { force: true });
}

async function deliver(entry: Entry, notification: Notification): Promise<void> {
	const { deviceId, machineId, machineName, platform } = entry.registration;
	let outcome: Outcome;
	try {
		outcome = await post(entry.registration, payloadJson(notification, machineId, machineName));
		if (!outcome.ok && outcome.gone) {
			await deleteIfUnchanged(entry);
			return;
		}
	} catch (error) {
		outcome = { ok: false, gone: false, message: errorText(error) };
	}
	if (outcome.ok) warned.delete(`relay:${deviceId}`);
	else warnOnce(`relay:${deviceId}`, `Push notifications to ${platform} device ${deviceId} fail: ${outcome.message}`);
}

async function broadcast(kind: Kind, notification: Notification): Promise<void> {
	const entries = await readRegistrations();
	await Promise.all(
		entries.filter(entry => entry.registration.kinds.includes(kind)).map(entry => deliver(entry, notification)),
	);
}

/** The detached run this process is; unset in the control process and in an omp started from inside a run. */
let detached: { session: AgentSession; runId: string } | undefined;
/** Between an `agent_start` and the terminal `agent_end` that settles the run. */
let runOpen = false;
/** A non-terminal `agent_end` came and no `agent_start` since: omp is about to start the run's next turn itself. */
let paused = false;
/** The `done` body a goal completion or loop end gave the open run. */
let settledBody: string | undefined;
/** `finalError` of the open run's retries that gave up. */
let retryError: string | undefined;

/** Starts sending `kind` to every registered phone that wants it, without waiting; failures become warnings. */
function send(kind: Kind, body: string): void {
	const run = detached;
	if (!run) return;
	const manager = run.session.sessionManager;
	const notification: Notification = {
		kind,
		runId: run.runId,
		sessionPath: manager.getSessionFile() ?? null,
		title: sessionTitle(manager.getSessionName(), firstUserMessage(manager.getEntries()), manager.getCwd()),
		body,
		ts: Date.now(),
	};
	broadcast(kind, notification).catch(error =>
		warnOnce(`dir:${pushDir()}`, `Push notifications fail: ${errorText(error)}`),
	);
}

/** A dialog opened: `body` is the question, the approval or the dialog's title. */
export function notifyInput(body: string): void {
	send("input", body);
}

/**
 * A goal completed or a loop ended with `body`. The open run's terminal `agent_end` sends it; with no run open it goes
 * now.
 */
export function notifyDone(body: string): void {
	if (!detached) return;
	if (runOpen) settledBody = body;
	else send("done", body);
}

/** omp's tool approval (extensions/wrapper.ts): `select("Allow tool: <name>\n…", ["Approve", "Deny"])`. */
function selectBody(title: string, options: readonly ExtensionUISelectItem[]): string {
	const first = title.split("\n", 1)[0] ?? "";
	const approval = options.length === 2 && options[0] === "Approve" && options[1] === "Deny";
	return approval && first.startsWith("Allow tool: ") ? `Allow ${first.slice("Allow tool: ".length)}?` : title;
}

/**
 * Every omp, tool and extension dialog goes through the raw UI object's methods: tool approvals call them on it
 * directly, `ctx.ui` of every handler forwards to them.
 */
function watchDialogs(ui: ExtensionUIContext): void {
	const select = ui.select.bind(ui);
	const confirm = ui.confirm.bind(ui);
	const input = ui.input.bind(ui);
	const editor = ui.editor.bind(ui);
	ui.select = (...args: Parameters<ExtensionUIContext["select"]>) => {
		notifyInput(selectBody(args[0], args[1]));
		return select(...args);
	};
	ui.confirm = (...args: Parameters<ExtensionUIContext["confirm"]>) => {
		notifyInput(args[0]);
		return confirm(...args);
	};
	ui.input = (...args: Parameters<ExtensionUIContext["input"]>) => {
		notifyInput(args[0]);
		return input(...args);
	};
	ui.editor = (...args: Parameters<ExtensionUIContext["editor"]>) => {
		notifyInput(args[0]);
		return editor(...args);
	};
}

function runEnded(messages: readonly AgentMessage[], continues: boolean): void {
	runOpen = false;
	paused = false;
	const body = settledBody;
	const retry = retryError;
	settledBody = undefined;
	retryError = undefined;
	if (continues) return;
	const last = messages.findLast((message): message is AssistantMessage => message.role === "assistant");
	// The user stopped it: they are there.
	if (last?.stopReason === "aborted") return;
	if (last?.stopReason === "error") send("failed", last.errorMessage ?? retry ?? "Unknown error");
	else if (retry !== undefined) send("failed", retry);
	else send("done", body ?? doneBody(last));
}

/** Ends the open run, if any, with `failed`: no terminal `agent_end` will come for it. */
function failRun(error: string): void {
	runOpen = false;
	paused = false;
	settledBody = undefined;
	retryError = undefined;
	send("failed", error);
}

/**
 * Sends `input`, `done` and `failed` for a detached run. Call after the goal and loop hooks subscribed: their
 * `agent_end` handlers schedule the next turn (read through `continues`) and record a completion first.
 */
export function installNotifications(
	session: AgentSession,
	ui: ExtensionUIContext,
	run: IdleRun,
	continues: () => boolean,
): void {
	detached = { session, runId: path.basename(run.dir) };
	watchDialogs(ui);
	session.subscribe(event => {
		switch (event.type) {
			case "agent_start":
				runOpen = true;
				paused = false;
				retryError = undefined;
				return;
			case "auto_retry_end": {
				if (event.success) return;
				const error = event.finalError ?? "Unknown error";
				// An attempt that gave up inside the run: the run's `agent_end` follows. A retry scheduled after a
				// non-terminal `agent_end` whose `continue()` failed before its turn started
				// (turn-recovery.ts #failRetryAfterLocalContinueError) is followed by nothing.
				if (runOpen && !paused) retryError = error;
				else failRun(error);
				return;
			}
			case "agent_end":
				if (event.isTerminal !== false) runEnded(event.messages, continues());
				// omp holds back the `agent_end` of a run a prompt still waits on and emits it, non-terminal, once the
				// prompt returns: after the failed retry's `auto_retry_end`, with nothing after it. Once retries gave up,
				// whatever omp starts next is a run of its own.
				else if (retryError !== undefined) failRun(retryError);
				else paused = true;
				return;
		}
	});
}

export const notifyVerbs: VerbTable = {
	"notify.test": async (args, { callId }) => {
		expectKeys(args, []);
		const entry = await readRegistration(callId.split(":", 1)[0] ?? "");
		const { deviceId, machineId, machineName } = entry.registration;
		const notification: Notification = {
			kind: "test",
			runId: null,
			sessionPath: null,
			title: "ompanion",
			body: `Notifications from ${machineName} work.`,
			ts: Date.now(),
		};
		const outcome = await post(entry.registration, payloadJson(notification, machineId, machineName));
		if (outcome.ok) {
			warned.delete(`relay:${deviceId}`);
			return {};
		}
		if (outcome.gone) await deleteIfUnchanged(entry);
		throw new VerbError("failed", outcome.message);
	},
};
