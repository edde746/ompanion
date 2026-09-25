import { describe, expect, test } from "bun:test";
import type { ExtensionUIContext } from "@oh-my-pi/pi-coding-agent";
import { Channel, errorFrame, eventFrame, replyFrame, responseValue } from "../src/channel.ts";

describe("frames", () => {
	test("replies always carry result or error", () => {
		expect(JSON.parse(JSON.stringify(replyFrame("a:1", undefined)))).toEqual({
			type: "ompx",
			kind: "reply",
			callId: "a:1",
			ok: true,
			result: null,
		});
		expect(errorFrame(null, "bad_request", "no")).toEqual({
			type: "ompx",
			kind: "reply",
			callId: null,
			ok: false,
			error: { code: "bad_request", message: "no" },
		});
	});

	test("events carry callId only for streaming calls", () => {
		expect(eventFrame("pause.changed", { paused: true })).toEqual({
			type: "ompx",
			kind: "event",
			event: "pause.changed",
			data: { paused: true },
		});
		expect(eventFrame("exec.chunk", "out", "a:2")).toMatchObject({ callId: "a:2" });
	});
});

describe("responseValue", () => {
	test("value is JSON; cancelled is undefined", () => {
		expect(responseValue({ type: "extension_ui_response", id: "x", value: '{"kind":"chat"}' })).toEqual({
			kind: "chat",
		});
		expect(responseValue({ type: "extension_ui_response", id: "x", value: "null" })).toBeNull();
		expect(responseValue({ type: "extension_ui_response", id: "x", cancelled: true })).toBeUndefined();
	});

	test("anything else is an error", () => {
		expect(() => responseValue({ type: "extension_ui_response", id: "x", value: "{" })).toThrow("not valid JSON");
		expect(() => responseValue({ type: "extension_ui_response", id: "x", confirmed: true })).toThrow();
		expect(() => responseValue({ type: "extension_ui_response", id: "x", value: 3 })).toThrow();
	});
});

/** Stands in for omp's `RpcExtensionUIContext`: `output` plus the `pendingRequests` map it resolves. */
class FakeRpcUi {
	readonly frames: Record<string, unknown>[] = [];
	readonly pendingRequests = new Map<string, { resolve(response: unknown): void; reject(error: Error): void }>();
	output = (frame: object): void => {
		this.frames.push(JSON.parse(JSON.stringify(frame)));
	};
	/** What omp's input loop does with an `extension_ui_response` frame. */
	respond(response: { id: string } & Record<string, unknown>): void {
		this.pendingRequests.get(response.id)?.resolve({ type: "extension_ui_response", ...response });
	}
	settledIds(): unknown[] {
		return this.frames
			.filter(frame => frame.kind === "event" && frame.event === "request.settled")
			.map(frame => (frame.data as { id: string }).id);
	}
	lastRequestId(): string {
		const last = this.frames.findLast(frame => frame.kind === "request");
		if (typeof last?.id !== "string") throw new Error("no request frame");
		return last.id;
	}
}

function rpcChannel(): { ui: FakeRpcUi; channel: Channel } {
	const ui = new FakeRpcUi();
	const channel = new Channel(ui as unknown as ExtensionUIContext);
	expect(channel.kind).toBe("output");
	return { ui, channel };
}

describe("requests", () => {
	test("the first answer wins and settles once", async () => {
		const { ui, channel } = rpcChannel();
		const answer = channel.request("ask", { questions: [] });
		const id = ui.lastRequestId();
		expect(ui.frames[0]).toEqual({ type: "ompx", kind: "request", id, method: "ask", params: { questions: [] } });
		expect(channel.openRequests()).toEqual([{ id, method: "ask", params: { questions: [] } }]);
		ui.respond({ id, value: '{"kind":"chat"}' });
		ui.respond({ id, value: '{"kind":"submit","results":[]}' });
		expect(await answer).toEqual({ kind: "chat" });
		expect(ui.settledIds()).toEqual([id]);
		expect(ui.pendingRequests.has(id)).toBe(false);
		expect(channel.openRequests()).toEqual([]);
	});

	test("abort resolves undefined and dismisses the dialog everywhere", async () => {
		const { ui, channel } = rpcChannel();
		const controller = new AbortController();
		const answer = channel.request("ask", {}, controller.signal);
		const id = ui.lastRequestId();
		controller.abort();
		expect(await answer).toBeUndefined();
		expect(ui.settledIds()).toEqual([id]);
		expect(ui.pendingRequests.has(id)).toBe(false);
	});

	test("a malformed answer fails the request", async () => {
		const { ui, channel } = rpcChannel();
		const answer = channel.request("ask", {});
		ui.respond({ id: ui.lastRequestId(), value: "not json" });
		await expect(answer).rejects.toThrow("not valid JSON");
	});

	test("a closed RPC input rejects before any frame is sent", async () => {
		const { ui, channel } = rpcChannel();
		const closed = new Error("RPC client disconnected");
		// RpcPendingExtensionRequests.set rejects synchronously once stdin has closed.
		ui.pendingRequests.set = (_id, pending) => {
			pending.reject(closed);
			return ui.pendingRequests;
		};
		await expect(channel.request("ask", {})).rejects.toBe(closed);
		expect(ui.frames).toEqual([]);
		expect(channel.openRequests()).toEqual([]);
	});
});

describe("fallback channel", () => {
	test("without omp's private fields every frame becomes an ompx status text", () => {
		const statuses: [string, string | undefined][] = [];
		const ui = { setStatus: (key: string, text: string | undefined) => statuses.push([key, text]) };
		const channel = new Channel(ui as unknown as ExtensionUIContext);
		expect(channel.kind).toBe("status");
		const frame = eventFrame("queue.changed", { steering: ["a\nb"], followUp: [], count: 1 });
		channel.send(frame);
		expect(statuses).toHaveLength(1);
		expect(statuses[0]?.[0]).toBe("ompx");
		expect(JSON.parse(statuses[0]?.[1] ?? "")).toEqual(frame);
		expect(() => channel.request("ask", {})).toThrow("fallback channel");
	});
});
