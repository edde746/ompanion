/**
 * An omp extension that `pause.e2e.test.ts` loads next to the companion (`-e`). `/agent-steer <text>` queues `text`
 * as a steer an agent handed off (`attribution: "agent"`), as an extension or a parent agent does: omp 18.4.4+ leaves
 * such messages out of `getQueuedMessages()`, older versions list them.
 */
import type { ExtensionAPI } from "@oh-my-pi/pi-coding-agent";

export default function agentSteer(pi: ExtensionAPI): void {
	pi.registerCommand("agent-steer", {
		description: "Test only: queue a steer attributed to the agent",
		handler: async args => {
			pi.sendUserMessage(args, { deliverAs: "steer", attribution: "agent" });
		},
	});
}
