import { afterEach, expect, test } from "bun:test";
import type { VerbContext } from "../src/protocol.ts";
import { loopState, loopVerbs } from "../src/verbs/session/loop.ts";
import "./rpc-ui.ts";

async function call(verb: string, args: Record<string, unknown>, session: object): Promise<unknown> {
	const handler = loopVerbs[verb];
	if (!handler) throw new Error(`${verb} is not registered`);
	// The loop verbs read only `session`; the fake implements the part of AgentSession they touch.
	return handler(args, { session } as unknown as VerbContext);
}

afterEach(async () => {
	await call("loop.disable", {}, {});
});

test("a body steered for a loop that was disabled meanwhile does not become the next loop's prompt", async () => {
	const steer = Promise.withResolvers<boolean>();
	const session = { isStreaming: true, prompt: () => steer.promise };
	await call("loop.enable", { limit: null, condition: null, prompt: "check the build" }, session);
	await call("loop.disable", {}, session);
	await call("loop.enable", { limit: null, condition: null, prompt: null }, session);
	steer.resolve(true);
	// `submitLoopBody` sees the steer's result a few microtasks later; a macrotask runs after all of them.
	const flushed = Promise.withResolvers<void>();
	setImmediate(flushed.resolve);
	await flushed.promise;
	expect(loopState()).toMatchObject({ paused: false, prompt: null });
});
