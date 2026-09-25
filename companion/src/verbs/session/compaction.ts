import type { AgentSession, ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { emitEvent } from "../../channel.ts";

const POLL_MS = 250;

let open = false;
let poll: Timer | undefined;

function end(entry: Record<string, unknown> | null): void {
	open = false;
	clearInterval(poll);
	poll = undefined;
	emitEvent("compaction.ended", { entry });
}

/**
 * omp sends no RPC frame for a manual compaction (the `/compact` prompt or RPC `compact`) until it ends:
 * `auto_compaction_*` covers only automatic ones. `session.compacting` fires before the summary is made, also
 * for background speculation, which `isCompacting` leaves out. `session_before_compact` would fire earlier, but
 * a handler for it turns speculative compaction off (session-maintenance.ts:2029). A failed or cancelled
 * compaction emits nothing, so `isCompacting` is polled until it clears. Every committed compaction ends with its
 * entry, started or not.
 */
export function installCompactionEvents(pi: ExtensionAPI, session: AgentSession): void {
	pi.on("session.compacting", () => {
		if (open || !session.isCompacting) return;
		open = true;
		emitEvent("compaction.started", {});
		poll = setInterval(() => {
			if (open && !session.isCompacting) end(null);
		}, POLL_MS);
		poll.unref();
	});
	pi.on("session_compact", event => {
		// `details` and `preserveData` can hold a whole snapcompact archive; the divider needs neither.
		const { details: _details, preserveData: _preserveData, ...entry } = event.compactionEntry;
		end(entry);
	});
}
