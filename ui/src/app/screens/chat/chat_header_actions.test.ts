// Port of the contract cases of test/screens/chat/chat_header_test.dart: what Stop sends and in which order, where the
// queue goes, which commands the session menu starts, and what a failed stop of the omp process says. Left out as
// markup and wiring: tapping the header's buttons and the menu (the menu's entries come from sessionMenuCommands).
import { expect, test } from "bun:test";
import { CompanionClient, type CompanionHello } from "../../../core/companion/companion_client";
import { asJsonObject } from "../../../core/rpc/json_fields";
import { RpcClient } from "../../../core/rpc/rpc_client";
import type { LinkState, LiveSession } from "../../../core/session/live_session";
import { type LoopState, type SessionView, type SlashCommand, sessionView } from "../../../core/store/session_view";
import { HostLinkException } from "../../../core/transport/host_link";
import type { LineChannel } from "../../../core/transport/line_channel";
import { Emitter, type EventStream } from "../../../core/util/stream";
import { ComposerDraft } from "../../sessions/composer_draft";
import { abortRunWith, sessionMenuCommands, stopSession } from "./chat_header_actions";

/**
 * An omp with the companion loaded that accepts every command; companion calls answer from `results` by verb. Logs
 * commands and companion calls in the order they arrive.
 */
class Omp implements LineChannel {
  private readonly emitter = new Emitter<string>({ buffered: true });
  readonly log: unknown[] = [];

  constructor(private readonly results: Readonly<Record<string, unknown>>) {}

  get lines(): EventStream<string> {
    return this.emitter.stream;
  }

  async send(line: string): Promise<void> {
    const json = asJsonObject(JSON.parse(line), "command");
    const id = json.id;
    if (id === undefined) return;
    const data = json.type === "negotiate_protocol" ? { protocolVersion: 2 } : undefined;
    const message = json.message;
    const call =
      typeof message === "string" && message.startsWith("/ompx ")
        ? asJsonObject(JSON.parse(message.substring("/ompx ".length)), "ompx call")
        : undefined;
    this.log.push(call === undefined ? json.type : { verb: call.verb, args: call.args });
    queueMicrotask(() => {
      this.emitter.add(JSON.stringify({ type: "response", id, command: json.type, success: true, data }));
      if (call !== undefined) {
        const result = this.results[String(call.verb)];
        this.emitter.add(JSON.stringify({ type: "ompx", kind: "reply", callId: call.callId, ok: true, result }));
      }
    });
  }

  async close(): Promise<void> {
    this.emitter.close();
  }
}

/** A session whose run streams while paused, with messages queued, and `loop` on. */
class PausedSession implements LiveSession {
  readonly runId = "run";
  readonly sessionPath = "/tmp/s.jsonl";
  readonly cwd = "/tmp";
  readonly linkState: LinkState = { kind: "LinkLive" };
  readonly linkStates: EventStream<LinkState> = new Emitter<LinkState>().stream;
  readonly views: EventStream<SessionView> = new Emitter<SessionView>().stream;
  readonly loadEarlier = undefined;
  readonly rpc: RpcClient;
  readonly companion: CompanionClient;
  readonly view: SessionView;
  readonly companionHello: CompanionHello;

  constructor(
    readonly omp: Omp,
    options: { loop?: LoopState; verbs?: readonly string[]; commands?: readonly SlashCommand[] } = {},
  ) {
    this.rpc = new RpcClient(omp, { deviceId: "test" });
    this.companion = new CompanionClient(this.rpc);
    this.view = sessionView({
      run: { running: true, paused: true, outcome: { kind: "RunIdle" } },
      queue: { count: 2, steering: ["steer me"], followUp: ["later"] },
      loop: options.loop,
      commands: options.commands ?? [],
    });
    this.companionHello = {
      companionVersion: "0.1.0",
      ompVersion: "18.3.1",
      channel: "output",
      verbs: options.verbs ?? ["queue.clear", "pause.set"],
      events: [],
    };
  }

  dismissRequest(): void {}
  setPendingPrompt(): void {}
  dismissNotice(): void {}
  reconnectNow(): void {}
  async detach(): Promise<void> {}
  async stop(): Promise<void> {}
}

/** A session whose omp cannot be stopped because the machine is unreachable. */
class UnreachableSession extends PausedSession {
  override async stop(): Promise<void> {
    throw new HostLinkException("the machine is off the network");
  }
}

/** Stops the run of a fresh paused session over `omp` and returns what omp received. */
async function stop(omp: Omp, options: { loop?: LoopState; verbs?: readonly string[] } = {}): Promise<unknown[]> {
  const session = new PausedSession(omp, options);
  await session.rpc.attach();
  omp.log.length = 0;
  await abortRunWith(session, new ComposerDraft(), () => {});
  return omp.log;
}

const plainStop = [{ verb: "queue.clear", args: { interrupt: true } }, "abort", { verb: "pause.set", args: { paused: false } }];

test("a stop that fails says why", async () => {
  const snacks: string[] = [];
  await stopSession({ stop: (session) => session.stop() }, new UnreachableSession(new Omp({})), (text) =>
    snacks.push(text),
  );
  expect(snacks).toEqual(["Could not stop the omp process: the machine is off the network"]);
});

// The TUI's Esc: queued messages come back into the editor, and nothing is left to hold the run paused.
test("Stop takes the queue back into the draft, aborts, and releases the pause", async () => {
  const omp = new Omp({
    "queue.clear": {
      steering: [{ text: "steer me" }],
      followUp: [{ text: "later", images: [{ data: "QUEUED", mimeType: "image/png" }] }],
    },
    "pause.set": { paused: false, pausedAt: null },
  });
  const session = new PausedSession(omp);
  await session.rpc.attach();
  omp.log.length = 0;
  const draft = new ComposerDraft();
  draft.replace("half typed");
  await abortRunWith(session, draft, () => {});

  expect(omp.log).toEqual(plainStop);
  expect(draft.text.text).toBe("steer me\n\nlater\n\nhalf typed");
  expect(draft.attachments.map((attachment) => attachment.kind === "ImageAttachment" && attachment.image.data)).toEqual([
    "QUEUED",
  ]);
});

// The TUI's Esc on a loop: the loop is suspended before the abort, whose turn end would start its next iteration.
test("Stop with a running loop suspends it before the abort", async () => {
  const results = {
    "queue.clear": { steering: [], followUp: [] },
    "loop.suspend": { loop: null },
    "pause.set": { paused: false, pausedAt: null },
  };
  const verbs = ["queue.clear", "pause.set", "loop.suspend"];
  const running: LoopState = { paused: false, prompt: "fix the next failing test", iterations: 2 };
  expect(await stop(new Omp(results), { loop: running, verbs })).toEqual([
    { verb: "queue.clear", args: { interrupt: true } },
    { verb: "loop.suspend", args: {} },
    "abort",
    { verb: "pause.set", args: { paused: false } },
  ]);
  // Already suspended, or a companion without the verb: nothing more than the plain Stop.
  expect(await stop(new Omp(results), { loop: { paused: true, iterations: 2 }, verbs })).toEqual(plainStop);
  expect(await stop(new Omp(results), { loop: running, verbs: ["queue.clear", "pause.set"] })).toEqual(plainStop);
});

test("the session menu starts /goal, /guided-goal and /loop in the composer, /loop only while no loop is on", () => {
  const command = (name: string): SlashCommand => ({ name, aliases: [], subcommands: [], source: "extension" });
  const commands = [command("goal"), command("guided-goal"), command("loop")];
  expect(sessionMenuCommands(sessionView({ commands }))).toEqual(["goal", "guided-goal", "loop"]);
  expect(sessionMenuCommands(sessionView({ commands: [command("loop")] }))).toEqual(["loop"]);
  // `/loop` while a loop is on turns it off, whatever follows.
  expect(sessionMenuCommands(sessionView({ commands, loop: { paused: false, iterations: 0 } }))).toEqual([
    "goal",
    "guided-goal",
  ]);

  const draft = new ComposerDraft();
  draft.replace("fix the flaky test");
  draft.takeFocusRequest();
  draft.startCommand("goal");
  expect(draft.text.text).toBe("/goal fix the flaky test");
  expect(draft.takeFocusRequest()).toBe(true);
  draft.replace("");
  draft.startCommand("guided-goal");
  expect(draft.text.text).toBe("/guided-goal ");
  draft.replace("");
  draft.startCommand("loop");
  expect(draft.text.text).toBe("/loop ");
});
