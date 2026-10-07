import * as fs from "node:fs/promises";
import * as path from "node:path";
import {
	type AgentSession,
	type ExtensionAPI,
	FileSessionStorage,
	type SessionInfo,
	SessionManager,
} from "@oh-my-pi/pi-coding-agent";
import { resolveLocalRoot } from "@oh-my-pi/pi-coding-agent/internal-urls/local-protocol";
import {
	computeSessionContextBreakdown,
	getSessionCompactionBoundaries,
} from "@oh-my-pi/pi-coding-agent/session/context-usage-runtime";
import {
	filterSessionsForPicker,
	listAllSessions,
	listSessions,
} from "@oh-my-pi/pi-coding-agent/session/session-listing";
import { loadPinnedSessionIds, sortPinnedFirst } from "@oh-my-pi/pi-coding-agent/session/session-pins";
import { getSessionsDir, isEnoent } from "@oh-my-pi/pi-utils";
import {
	expectKeys,
	optionalBoolean,
	optionalInteger,
	optionalString,
	requireNullableString,
	requireString,
} from "../args.ts";
import { isSessionFilePath } from "../paths.ts";
import { type CommandTable, VerbError, type VerbTable } from "../protocol.ts";
import { accountVerbs, installCredentialSync } from "./session/accounts.ts";
import { agentVerbs, installAgentRoster } from "./session/agents.ts";
import { btwVerbs } from "./session/btw.ts";
import { announceChange, sessionState } from "./session/changes.ts";
import { installCompactionEvents } from "./session/compaction.ts";
import { execVerbs, installExecMessageEvents } from "./session/exec.ts";
import { goalCommands, goalVerbs, installGoalMode } from "./session/goal.ts";
import { historyVerbs, installHistoryRecording } from "./session/history.ts";
import { installLoopMode, loopCommands, loopVerbs } from "./session/loop.ts";
import { installAutoTitle } from "./session/title.ts";

/** Wire contract: docs/contracts/ompx.md, sections `sessions.list` through `loop.disable`. */

export const sessionEvents: readonly string[] = [
	"agents.changed",
	"session.changed",
	"exec.chunk",
	"message.appended",
	"btw.delta",
	"compaction.started",
	"compaction.ended",
	"loop.changed",
	"title.changed",
];

/** Called once per process from the main session's `session_start`, after the channel is bound. */
export async function installSessionHooks(pi: ExtensionAPI, session: AgentSession): Promise<void> {
	installAgentRoster(pi, session);
	installHistoryRecording(pi);
	installExecMessageEvents(pi);
	installCompactionEvents(pi, session);
	installLoopMode(session);
	installAutoTitle(pi, session);
	installCredentialSync(session);
	await installGoalMode(pi, session);
}

function sessionRow(info: SessionInfo, pinned: ReadonlySet<string>) {
	const created = info.created.getTime();
	return {
		path: info.path,
		id: info.id,
		cwd: info.cwd,
		title: info.title ?? null,
		// "(no messages)" is omp's display placeholder, not a message.
		firstMessage: info.firstMessage === "(no messages)" ? null : info.firstMessage,
		created: Number.isFinite(created) ? created : null,
		modified: info.modified.getTime(),
		messageCount: info.messageCount,
		assistantTurns: info.assistantTurns ?? null,
		size: info.size,
		status: info.status ?? "unknown",
		parent: info.parentSessionPath ?? null,
		pinned: pinned.has(info.id),
	};
}

/**
 * `deleteSessionWithArtifacts` also removes the sibling directory named after the file, so only files where omp
 * keeps sessions are accepted. A session that is not persisted (`--no-session`, the machine's control process)
 * has no directory of its own.
 */
async function assertDeletableSession(file: string, session: AgentSession): Promise<void> {
	const sessionDir = session.sessionFile === undefined ? "" : session.sessionManager.getSessionDir();
	if (!isSessionFilePath(file, getSessionsDir(), sessionDir)) {
		throw new VerbError("bad_request", `${file} is not a session file in omp's session directories`);
	}
	try {
		if (!(await fs.lstat(file)).isFile()) throw new VerbError("bad_request", `${file} is not a regular file`);
	} catch (error) {
		if (isEnoent(error)) throw new VerbError("not_found", `no session file ${file}`);
		throw error;
	}
}

const lifecycleVerbs: VerbTable = {
	// The TUI resume picker's list (SessionManager.listForPicker / listAllForPicker): pinned first, then
	// newest; untitled sessions without an answer are left out unless pinned.
	"sessions.list": async (args, { session }) => {
		expectKeys(args, ["cwd", "all", "limit", "offset"]);
		const all = optionalBoolean(args, "all") ?? false;
		const cwd = optionalString(args, "cwd");
		if (all && cwd !== undefined) throw new VerbError("bad_request", "pass cwd or all, not both");
		const limit = optionalInteger(args, "limit", 1, 1000) ?? 100;
		const offset = optionalInteger(args, "offset", 0, Number.MAX_SAFE_INTEGER) ?? 0;
		const manager = session.sessionManager;
		const pinned = await loadPinnedSessionIds();
		let scanned: SessionInfo[];
		if (all) {
			scanned = await listAllSessions();
		} else {
			const target = path.resolve(cwd ?? manager.getCwd());
			const dir =
				target === path.resolve(manager.getCwd())
					? manager.getSessionDir()
					: SessionManager.getDefaultSessionDir(target);
			scanned = await listSessions(dir, new FileSessionStorage());
		}
		const sessions = sortPinnedFirst(filterSessionsForPicker(scanned, pinned), pinned);
		return {
			total: sessions.length,
			offset,
			sessions: sessions.slice(offset, offset + limit).map(info => sessionRow(info, pinned)),
		};
	},

	"session.fork": async (args, { session }) => {
		expectKeys(args, []);
		if (session.isStreaming) {
			throw new VerbError("busy", "wait for the current response to finish or abort it before forking");
		}
		const parentSessionFile = session.sessionFile ?? null;
		if (!(await session.fork())) {
			throw new VerbError("failed", "fork failed: the session is not persisted, or an extension cancelled it");
		}
		return { ...announceChange("fork", session), parentSessionFile };
	},

	// The TUI's /clear (command-controller.ts:1105-1134): stop compaction, then reset the context in place.
	"session.clear": async (args, { session }) => {
		expectKeys(args, []);
		if (session.isCompacting) {
			session.abortCompaction();
			while (session.isCompacting) await Bun.sleep(10);
		}
		const result = await session.resetSessionContext();
		if (!result) {
			throw new VerbError("busy", "wait for the current response or command to finish, or abort it, before clearing");
		}
		return { droppedCount: result.droppedCount, ...announceChange("clear", session) };
	},

	"session.delete": async (args, { session }) => {
		expectKeys(args, ["path", "dropCurrent"]);
		const file = path.resolve(requireString(args, "path"));
		const dropCurrent = optionalBoolean(args, "dropCurrent") ?? false;
		const current = session.sessionFile;
		if (current === undefined || file !== path.resolve(current)) {
			if (dropCurrent) throw new VerbError("bad_request", "dropCurrent applies only to the open session's path");
			await assertDeletableSession(file, session);
			await new FileSessionStorage().deleteSessionWithArtifacts(file);
			return { deleted: file, current: false };
		}
		// The open file must be closed by its own SessionManager first, or its writer would recreate it:
		// the TUI's /delete (command-controller.ts:1136-1142) is newSession({drop: true}).
		if (!dropCurrent) {
			throw new VerbError(
				"bad_request",
				"path is the open session; pass dropCurrent: true to delete it and continue in a new session",
			);
		}
		if (session.isStreaming) {
			throw new VerbError("busy", "wait for the current response to finish or abort it before deleting");
		}
		if (!(await session.newSession({ drop: true }))) {
			throw new VerbError("failed", "an extension cancelled the new session; nothing was deleted");
		}
		const state = announceChange("delete", session);
		// newSession logs a failed unlink instead of throwing (agent-session.ts:8714-8719).
		if (await Bun.file(file).exists()) {
			throw new VerbError("failed", `a new session started, but ${file} could not be deleted (see omp's log)`);
		}
		return { deleted: file, current: true, ...state };
	},

	"tree.navigate": async (args, { session }) => {
		expectKeys(args, ["entryId", "summarize", "customInstructions"]);
		const entryId = requireString(args, "entryId");
		const summarize = optionalBoolean(args, "summarize") ?? false;
		const customInstructions = optionalString(args, "customInstructions");
		if (customInstructions !== undefined && !summarize) {
			throw new VerbError("bad_request", "customInstructions needs summarize: true");
		}
		if (!session.sessionManager.getEntry(entryId)) throw new VerbError("not_found", `no entry ${entryId}`);
		if (session.isStreaming) {
			throw new VerbError("busy", "wait for the current response to finish or abort it before navigating");
		}
		const leafBefore = session.sessionManager.getLeafId();
		const result = await session.navigateTree(entryId, { summarize, customInstructions });
		if (result.cancelled) return { cancelled: true, aborted: result.aborted === true };
		// omp returns without touching anything when the target already is the leaf (agent-session.ts navigateTree).
		const moved = result.summaryEntry !== undefined || session.sessionManager.getLeafId() !== leafBefore;
		return {
			cancelled: false,
			aborted: false,
			editorText: result.editorText ?? null,
			editorImages: result.editorImages ?? [],
			summaryEntryId: result.summaryEntry?.id ?? null,
			...(moved ? announceChange("tree", session) : sessionState(session)),
		};
	},

	// Esc while the TUI summarizes a branch (selector-controller.ts:1341-1343).
	"tree.abort": async (args, { session }) => {
		expectKeys(args, []);
		session.abortBranchSummary();
		return {};
	},

	"tree.label": async (args, { session }) => {
		expectKeys(args, ["entryId", "label"]);
		const entryId = requireString(args, "entryId");
		const label = requireNullableString(args, "label");
		const manager = session.sessionManager;
		if (!manager.getEntry(entryId)) throw new VerbError("not_found", `no entry ${entryId}`);
		manager.appendLabelChange(entryId, label ?? undefined);
		return { entryId, label: manager.getLabel(entryId) ?? null, ...announceChange("label", session) };
	},

	// The TUI's /context (command-controller.ts:705-712) as data instead of a rendered grid.
	"context.breakdown": async (args, { session }) => {
		expectKeys(args, []);
		const breakdown = computeSessionContextBreakdown(session, { snapcompactSavings: true });
		const model = breakdown.model;
		return {
			model: model ? { provider: model.provider, id: model.id, name: model.name } : null,
			contextWindow: breakdown.contextWindow,
			usedTokens: breakdown.usedTokens,
			autoCompactBufferTokens: breakdown.autoCompactBufferTokens,
			freeTokens: breakdown.freeTokens,
			categories: breakdown.categories.map(category => ({
				id: category.id,
				label: category.label,
				tokens: category.tokens,
			})),
			snapcompact: breakdown.snapcompact ?? null,
			boundaries: getSessionCompactionBoundaries(session.settings, breakdown.contextWindow, model),
		};
	},

	// Where `local://` points for the open session, as omp's read tool and the TUI's "Attach as local file" resolve
	// it. The app writes attachments there over SFTP; the directory may not exist yet.
	"session.localRoot": async (args, { session }) => {
		expectKeys(args, []);
		const manager = session.sessionManager;
		return {
			path: resolveLocalRoot({
				getArtifactsDir: () => manager.getArtifactsDir(),
				getSessionId: () => manager.getSessionId(),
			}),
		};
	},
};

export const sessionVerbs: VerbTable = {
	...lifecycleVerbs,
	...agentVerbs,
	...execVerbs,
	...historyVerbs,
	...accountVerbs,
	...btwVerbs,
	...goalVerbs,
	...loopVerbs,
};

/** Slash commands the TUI has as builtins that rpc-ui lacks (docs/contracts/ompx.md, "Slash commands"). */
export const sessionCommands: CommandTable = { ...goalCommands, ...loopCommands };
