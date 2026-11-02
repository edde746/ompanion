// A LiveSession for app tests (the `_Session` of test/dock/dock_companion_calls_test.dart): the real RpcClient and
// CompanionClient over a ScriptedChannel that plays omp. Every prompt is accepted; companion calls wait for `answer`.
import { CompanionClient, companionHelloFromJson } from "../core/companion/companion_client";
import { asJsonObject, type JsonObject } from "../core/rpc/json_fields";
import { RpcClient } from "../core/rpc/rpc_client";
import { type LinkState, linkLive, type LiveSession } from "../core/session/live_session";
import { type SessionView, sessionView } from "../core/store/session_view";
import { Emitter } from "../core/util/stream";
import { ScriptedChannel, startClient } from "./scripted_channel";

export interface FakeLiveSession {
  readonly session: LiveSession;
  readonly channel: ScriptedChannel;
  /** Emits views as `session.views`; `session.view` follows. */
  readonly views: Emitter<SessionView>;
  /** The `/ompx` calls sent so far, as `{callId, verb, args}`. */
  companionCalls(): JsonObject[];
  /** Replies to companion call `callId`: its result, or a failure with `errorCode`. */
  answer(callId: string, reply: { result?: unknown; errorCode?: string }): void;
}

/**
 * `withCompanion` decides whether the session has a companion `hello`, listing `verbs`. `answers` responds to RPC
 * commands by type (`get_tree`, `get_subagent_messages`, …) with the data a function returns.
 */
export async function fakeLiveSession(options: {
  withCompanion: boolean;
  verbs?: readonly string[];
  view?: SessionView;
  answers?: Readonly<Record<string, (command: JsonObject) => unknown>>;
}): Promise<FakeLiveSession> {
  const channel = new ScriptedChannel();
  const rpc = new RpcClient(channel, { deviceId: "test" });
  const companion = new CompanionClient(rpc);
  channel.answer("prompt", () => undefined);
  for (const [type, data] of Object.entries(options.answers ?? {})) channel.answer(type, data);
  await startClient(rpc, channel);
  const views = new Emitter<SessionView>();
  let view = options.view ?? sessionView();
  views.stream.listen((next) => {
    view = next;
  });
  const session: LiveSession = {
    runId: "run",
    sessionPath: "/tmp/s.jsonl",
    cwd: "/tmp",
    get view() {
      return view;
    },
    views: views.stream,
    linkState: linkLive,
    linkStates: new Emitter<LinkState>().stream,
    rpc,
    companion,
    companionHello: options.withCompanion
      ? companionHelloFromJson({
          companion: { version: "0.1.0" },
          omp: { version: "18.3.1" },
          channel: "output",
          verbs: [...(options.verbs ?? [])],
          events: [],
        })
      : undefined,
    loadEarlier: undefined,
    dismissRequest: () => undefined,
    setPendingPrompt: () => undefined,
    dismissNotice: () => undefined,
    reconnectNow: () => undefined,
    detach: async () => undefined,
    stop: async () => undefined,
  };
  return {
    session,
    channel,
    views,
    companionCalls: () =>
      channel.sent.flatMap((line) =>
        line.type === "prompt" && typeof line.message === "string" && line.message.startsWith("/ompx ")
          ? [asJsonObject(JSON.parse(line.message.substring("/ompx ".length)), "ompx call")]
          : [],
      ),
    answer: (callId, reply) =>
      channel.emit(
        reply.errorCode === undefined
          ? { type: "ompx", kind: "reply", callId, ok: true, result: reply.result ?? {} }
          : { type: "ompx", kind: "reply", callId, ok: false, error: { code: reply.errorCode, message: "agent released" } },
      ),
  };
}
