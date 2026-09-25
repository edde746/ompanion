import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { HistoryStorage } from "@oh-my-pi/pi-coding-agent/session/history-storage";
import { expectKeys, optionalInteger, optionalString } from "../../args.ts";
import type { VerbTable } from "../../protocol.ts";

/**
 * omp writes prompt history (history.db, read by the TUI's Up arrow and Ctrl+R) only from the TUI
 * editor, and RPC prompts never fire the `input` event (runner.emitInput has one caller,
 * input-controller.ts:974). So the companion records every user message the main session receives:
 * prompts, steers and follow-ups, after prompt-template expansion. Messages the agent or an extension
 * injects carry `attribution: "agent"` or `synthetic` and are skipped.
 */
export function installHistoryRecording(pi: ExtensionAPI): void {
	pi.on("message_end", (event, ctx) => {
		const message = event.message;
		if (message.role !== "user" || message.synthetic || message.attribution === "agent") return;
		const text =
			typeof message.content === "string"
				? message.content
				: message.content
						.filter(part => part.type === "text")
						.map(part => part.text)
						.join("\n");
		void HistoryStorage.open().add(text, ctx.sessionManager.getCwd(), ctx.sessionManager.getSessionId());
	});
}

export const historyVerbs: VerbTable = {
	"history.search": async args => {
		expectKeys(args, ["query", "limit"]);
		const query = optionalString(args, "query");
		const limit = optionalInteger(args, "limit", 1, 1000) ?? 100;
		const history = HistoryStorage.open();
		const entries = query === undefined ? history.getRecent(limit) : history.search(query, limit);
		return {
			entries: entries.map(entry => ({
				prompt: entry.prompt,
				createdAt: entry.created_at * 1000,
				cwd: entry.cwd ?? null,
				sessionId: entry.sessionId ?? null,
				useCount: entry.useCount,
			})),
		};
	},
};
