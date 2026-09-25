import type { Message } from "@oh-my-pi/pi-ai";
import {
	type BtwHistoryRecord,
	BtwHistoryStore,
	type BtwHistoryTurn,
	getBtwTurns,
} from "@oh-my-pi/pi-coding-agent/session/btw-history";
import { prompt, Snowflake } from "@oh-my-pi/pi-utils";
import { expectKeys, optionalString, requireString } from "../../args.ts";
import { emitEvent } from "../../channel.ts";
import { VerbError, type VerbTable } from "../../protocol.ts";

/** omp 18.3.1 `prompts/system/btw-user.md`; `.md` prompts are not importable from an extension in the compiled binary. */
const BTW_USER_PROMPT = `<btw>
Ephemeral side question for current interactive session.
Answer briefly, directly; use conversation context already provided.
NEVER use tools.
NEVER ask follow-up questions.
Question:
{{question}}
</btw>
`;

/** Like the TUI, one side question runs at a time per session process. */
let running: AbortController | undefined;

function patchLatestTurn(record: BtwHistoryRecord, patch: Partial<BtwHistoryTurn>): BtwHistoryRecord {
	const followUps = record.followUps;
	const last = followUps?.at(-1);
	if (!followUps || !last) return { ...record, ...patch };
	return { ...record, followUps: [...followUps.slice(0, -1), { ...last, ...patch }] };
}

export const btwVerbs: VerbTable = {
	// The TUI's /btw (btw-controller.ts:331-457, 573-653): an ephemeral side turn over the current
	// context, saved to the session's BTW history so the TUI's /btw history shows it too.
	btw: async (args, context) => {
		expectKeys(args, ["prompt", "recordId"]);
		const question = requireString(args, "prompt").trim();
		if (!question) throw new VerbError("bad_request", "prompt must not be blank");
		const recordId = optionalString(args, "recordId");
		const runEphemeralTurn = context.ctx.runEphemeralTurn;
		if (!runEphemeralTurn) throw new VerbError("unsupported", "this omp cannot run ephemeral turns");
		if (running) throw new VerbError("busy", "a side question is still running; wait for it or send btw.abort");
		const abort = new AbortController();
		running = abort;
		try {
			const session = context.session;
			const model = session.model;
			if (!model) throw new VerbError("failed", "no active model available for /btw");
			const manager = session.sessionManager;
			await manager.ensureOnDisk();
			const store = await BtwHistoryStore.open(manager.getArtifactsDir() ?? undefined);
			const previous = recordId === undefined ? undefined : store.getRecords().find(record => record.id === recordId);
			if (recordId !== undefined && !previous) throw new VerbError("not_found", `no side conversation ${recordId}`);
			const now = Date.now();
			const turn: BtwHistoryTurn = { question, answer: "", status: "running", createdAt: now, updatedAt: now };
			let record: BtwHistoryRecord = previous
				? { ...previous, followUps: [...(previous.followUps ?? []), turn] }
				: { ...turn, id: Snowflake.next(), leafId: manager.getLeafId() };
			const earlier = previous ? getBtwTurns(previous) : [];
			// A cancelled or failed transport may still be unwinding: start a fresh provider lineage after it.
			const transportEpoch = earlier.findLastIndex(item => item.status !== "complete") + 1;
			const history: Message[] = [];
			for (const item of earlier) {
				history.push({
					role: "user",
					content: [{ type: "text", text: prompt.render(BTW_USER_PROMPT, { question: item.question }) }],
					attribution: "agent",
					timestamp: item.createdAt,
				});
				if (!item.answer) continue;
				// Saved answers are visible text only, replayed as context rather than billed turns.
				history.push({
					role: "assistant",
					content: [{ type: "text", text: item.answer }],
					api: model.api,
					provider: model.provider,
					model: model.id,
					usage: {
						input: 0,
						output: 0,
						cacheRead: 0,
						cacheWrite: 0,
						totalTokens: 0,
						cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
					},
					stopReason: "stop",
					timestamp: item.updatedAt,
				});
			}
			await store.upsert(record);
			let streamed = "";
			let answer: string;
			try {
				const reply = await runEphemeralTurn({
					promptText: prompt.render(BTW_USER_PROMPT, { question }),
					history,
					conversationKey: `btw:${record.id}:${transportEpoch}`,
					onTextDelta: text => {
						streamed += text;
						emitEvent("btw.delta", { text }, context.callId);
					},
					signal: abort.signal,
				});
				answer = reply.replyText;
			} catch (error) {
				const cancelled = abort.signal.aborted;
				record = patchLatestTurn(record, {
					answer: streamed,
					status: cancelled ? "cancelled" : "error",
					updatedAt: Date.now(),
					...(cancelled ? {} : { error: error instanceof Error ? error.message : String(error) }),
				});
				await store.upsert(record);
				if (!cancelled) throw error;
				return { recordId: record.id, status: "cancelled", answer: streamed };
			}
			record = patchLatestTurn(record, { answer, status: "complete", updatedAt: Date.now() });
			await store.upsert(record);
			return { recordId: record.id, status: "complete", answer };
		} finally {
			running = undefined;
		}
	},

	"btw.abort": async args => {
		expectKeys(args, []);
		const active = running;
		active?.abort();
		return { aborted: active !== undefined };
	},
};
