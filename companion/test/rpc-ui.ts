import type { ExtensionUIContext } from "@oh-my-pi/pi-coding-agent";
import { bindChannel, type OmpxFrame } from "../src/channel.ts";

/**
 * omp's RPC UI as the process-wide channel uses it, bound on import. Bun runs every test file in one process and one
 * module graph, and the channel binds once per process, so every test that needs `channel()` shares this one.
 */
export const rpcUi = {
	frames: [] as OmpxFrame[],
	pendingRequests: new Map<string, unknown>(),
	output(frame: OmpxFrame): void {
		this.frames.push(frame);
	},
	notify(): void {},
};

// The double implements only the members `Channel` reads.
bindChannel(rpcUi as unknown as ExtensionUIContext);

/** The `event` frames named `event` sent since `since` (an index into {@link rpcUi.frames}). */
export function eventsSince(since: number, event: string): OmpxFrame[] {
	return rpcUi.frames.slice(since).filter(frame => frame.kind === "event" && frame.event === event);
}
