import type { AgentSession, ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { emitEvent } from "../../channel.ts";

/**
 * omp 18.3.1 names a session from its first user message only in the TUI (input-controller.ts) and for a CLI's
 * initial message (main.ts): rpc and rpc-ui mode set `PI_NO_TITLE`, and the RPC `prompt` never calls
 * `maybeStartTitleGeneration`. A session started from a device would stay untitled for good. The companion lifts
 * that switch and makes the TUI's call for every user message the main session receives (the messages
 * history.ts records), so omp's own gate applies: only an unnamed session, no greetings, one request at a time,
 * and a retry from the conversation once a declined message has an answer. Lifting the switch also brings back
 * the TUI's retitle after a todo replan. omp sends no frame for a title it sets, so every change is reported.
 */
export function installAutoTitle(pi: ExtensionAPI, session: AgentSession): void {
	delete Bun.env.PI_NO_TITLE;
	pi.on("message_end", event => {
		const message = event.message;
		if (message.role !== "user" || message.synthetic || message.attribution === "agent") return;
		const text =
			typeof message.content === "string"
				? message.content
				: message.content
						.filter(part => part.type === "text")
						.map(part => part.text)
						.join("\n");
		session.maybeStartTitleGeneration(text);
	});
	session.sessionManager.onSessionNameChanged(() => {
		const title = session.sessionName;
		if (title) emitEvent("title.changed", { title });
	});
}
