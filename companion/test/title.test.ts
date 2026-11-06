import { expect, test } from "bun:test";
import type { AgentSession, ExtensionAPI } from "@oh-my-pi/pi-coding-agent";
import { installAutoTitle } from "../src/verbs/session/title.ts";

/** The parts of omp 18.8.7+ `installAutoTitle` touches; `generateTitle` waits until the test answers it. */
function titledSession() {
	const requests: { sessionId: string; reply: PromiseWithResolvers<string | undefined> }[] = [];
	const session = {
		sessionId: "A",
		sessionName: undefined,
		sessionManager: {
			getSessionId: () => session.sessionId,
			setSessionName: async () => {},
			onSessionNameChanged: () => {},
		},
		generateTitle(): Promise<string | undefined> {
			const reply = Promise.withResolvers<string | undefined>();
			requests.push({ sessionId: session.sessionId, reply });
			return reply.promise;
		},
	};
	let messageEnd: ((event: { message: unknown }) => void) | undefined;
	const pi = {
		on(event: string, handler: (event: { message: unknown }) => void): void {
			if (event === "message_end") messageEnd = handler;
		},
	};
	// The fakes implement the part of omp's API and session `installAutoTitle` touches.
	installAutoTitle(pi as unknown as ExtensionAPI, session as unknown as AgentSession);
	const userMessage = (text: string): void => messageEnd?.({ message: { role: "user", content: text } });
	return { session, requests, userMessage };
}

/** Declines a title request and lets its `finally` run: a macrotask runs after every microtask it queued. */
async function decline(request: { reply: PromiseWithResolvers<string | undefined> } | undefined): Promise<void> {
	request?.reply.resolve(undefined);
	const flushed = Promise.withResolvers<void>();
	setImmediate(flushed.resolve);
	await flushed.promise;
}

test("a session gets one title request at a time, also after switching away and back", async () => {
	const { session, requests, userMessage } = titledSession();
	userMessage("fix the parser");
	session.sessionId = "B";
	userMessage("write the docs");
	session.sessionId = "A";
	userMessage("and the lexer");
	expect(requests.map(request => request.sessionId)).toEqual(["A", "B"]);

	// B's request ending does not end A's.
	await decline(requests[1]);
	userMessage("and the tests");
	expect(requests.map(request => request.sessionId)).toEqual(["A", "B"]);

	// A declined message lets the next one ask again.
	await decline(requests[0]);
	userMessage("and the tests");
	expect(requests.map(request => request.sessionId)).toEqual(["A", "B", "A"]);
});
