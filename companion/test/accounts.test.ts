import { describe, expect, test } from "bun:test";
import type { VerbContext } from "../src/protocol.ts";
import { accountVerbs } from "../src/verbs/session/accounts.ts";

/**
 * The parts of an AgentSession `accounts.pin` reads, for an OAuth provider without a key override. rpc-mode does not
 * await `/ompx` handlers, so commands from other devices run while the verb awaits the credential reload;
 * `duringReload` plays them. The pin mirrors omp's `pinCurrentProviderOAuthAccount` (false while streaming).
 */
function fakeSession(duringReload: (session: { isStreaming: boolean }) => void) {
	const session = {
		sessionId: "s1",
		model: { provider: "anthropic" },
		isStreaming: false,
		modelRegistry: {
			authStorage: {
				keys: { source: () => ({ kind: "oauth", concrete: true }) },
				credentials: {
					reload: async () => {
						await Promise.resolve();
						duringReload(session);
					},
					list: () => [{ id: 7, credential: { type: "oauth" } }],
				},
			},
		},
		pinCurrentProviderOAuthAccount: () => !session.isStreaming,
	};
	return session;
}

async function pin(session: object, credentialId: number): Promise<unknown> {
	const verb = accountVerbs["accounts.pin"];
	if (!verb) throw new Error("accounts.pin is not registered");
	// The verb reads only `session`; the fake implements the part of AgentSession it touches.
	return verb({ credentialId }, { session } as unknown as VerbContext);
}

describe("accounts.pin", () => {
	test("a turn another device started during the credential reload makes it busy, not an override failure", async () => {
		const session = fakeSession(session => {
			session.isStreaming = true;
		});
		await expect(pin(session, 7)).rejects.toMatchObject({ code: "busy" });
	});

	test("pins a listed account of the model's provider", async () => {
		expect(await pin(fakeSession(() => {}), 7)).toEqual({ provider: "anthropic", credentialId: 7 });
		await expect(pin(fakeSession(() => {}), 8)).rejects.toMatchObject({ code: "not_found" });
	});
});
