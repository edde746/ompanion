import { type AgentSession, type ExtensionAPI, logger } from "@oh-my-pi/pi-coding-agent";
import { emitEvent } from "../../channel.ts";

/** omp before 18.8.7 gates and starts a session's auto-title through this method. */
type TitleGate = { maybeStartTitleGeneration?: (firstMessage: string) => void };

/**
 * omp names a session from its user messages only in the TUI: rpc and rpc-ui mode set `PI_NO_TITLE`, so a session
 * started from a device would stay untitled for good. The companion lifts that switch, which also brings back the
 * TUI's retitle after a todo replan, and titles every user message the main session receives (the messages
 * history.ts records). omp before 18.8.7 does this through `maybeStartTitleGeneration`, with its own gate: only an
 * unnamed session, no greetings, one request at a time, and a retry from the conversation once a declined message
 * has an answer. 18.8.7 made titling private to an interactive session (`autoTitle`), so there the companion makes
 * the same title-model request itself: only an unnamed session, one request at a time, and `generateTitle` declines a
 * greeting without asking the model; a declined message waits for the next one. omp sends no frame for a title it
 * sets, so every change is reported.
 */
export function installAutoTitle(pi: ExtensionAPI, session: AgentSession): void {
	delete Bun.env.PI_NO_TITLE;
	const gate = (session as AgentSession & TitleGate).maybeStartTitleGeneration?.bind(session);
	const title = gate ?? titleFromMessages(session);
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
		title(text);
	});
	session.sessionManager.onSessionNameChanged(() => {
		const name = session.sessionName;
		if (name) emitEvent("title.changed", { title: name });
	});
}

function titleFromMessages(session: AgentSession): (text: string) => void {
	let inFlight: string | undefined;
	return text => {
		const sessionId = session.sessionManager.getSessionId();
		if (session.sessionName || inFlight === sessionId) return;
		inFlight = sessionId;
		session
			.generateTitle(text)
			.then(async name => {
				// A rename or another session while the request ran wins.
				if (name && !session.sessionName && session.sessionManager.getSessionId() === sessionId) {
					await session.sessionManager.setSessionName(name, "auto");
				}
			})
			.catch((error: unknown) => {
				logger.warn("ompx: titling the session failed", { sessionId, error: String(error) });
			})
			.finally(() => {
				if (inFlight === sessionId) inFlight = undefined;
			});
	};
}
