// A LiveSession for app tests, as the Dart app tests fake one (test/sessions/exec_runs_test.dart's _Session): views
// the test emits, and an omp that accepts every command, answers companion calls when the test says so and writes the
// frames the test emits.
import { CompanionClient, type CompanionHello } from "../core/companion/companion_client";
import { asJsonObject } from "../core/rpc/json_fields";
import { RpcClient } from "../core/rpc/rpc_client";
import type { LinkState, LiveSession } from "../core/session/live_session";
import { type PendingPrompt, type SessionView, sessionView } from "../core/store/session_view";
import type { LineChannel } from "../core/transport/line_channel";
import { Emitter, type EventStream } from "../core/util/stream";

/** Accepts every command, prompts once `promptAnswer` says so; companion calls get their reply when the test sends it. */
export class FakeOmp implements LineChannel {
  private readonly emitter = new Emitter<string>({ buffered: true });
  /** Every command line sent, decoded. */
  readonly sent: Record<string, unknown>[] = [];
  /** The `callId` of the last companion call (`/ompx {…}` prompt). */
  lastCallId: string | undefined;
  /** While set, prompts are answered once it resolves, with its value as `success`. */
  promptAnswer: Promise<boolean> | undefined;

  get lines(): EventStream<string> {
    return this.emitter.stream;
  }

  /** The `prompt` commands sent, in order. */
  get prompts(): Record<string, unknown>[] {
    return this.sent.filter((line) => line.type === "prompt");
  }

  async send(line: string): Promise<void> {
    const json = asJsonObject(JSON.parse(line), "command");
    this.sent.push(json);
    if (json.type === "prompt" && typeof json.message === "string" && json.message.startsWith("/ompx ")) {
      const call = asJsonObject(JSON.parse(json.message.substring("/ompx ".length)), "ompx call");
      this.lastCallId = String(call.callId);
    }
    const id = json.id;
    if (id === undefined) return;
    const data = json.type === "negotiate_protocol" ? { protocolVersion: 2 } : undefined;
    const respond = (success: boolean) =>
      this.emit({
        type: "response",
        id,
        command: json.type,
        success,
        data,
        ...(success ? {} : { error: "Agent is busy" }),
      });
    const answer = json.type === "prompt" ? this.promptAnswer : undefined;
    if (answer === undefined) queueMicrotask(() => respond(true));
    else void answer.then(respond);
  }

  /** Writes `frame` as a line of omp's output, e.g. a `prompt_result`. */
  emit(frame: Record<string, unknown>): void {
    this.emitter.add(JSON.stringify(frame));
  }

  /** Replies to the last companion call with `result`. */
  reply(result: unknown): void {
    this.emit({ type: "ompx", kind: "reply", callId: this.lastCallId, ok: true, result });
  }

  async close(): Promise<void> {
    this.emitter.close();
  }
}

export class FakeLiveSession implements LiveSession {
  readonly runId = "run";
  readonly sessionPath: string | undefined = undefined;
  readonly cwd = "/tmp";
  readonly linkState: LinkState = { kind: "LinkLive" };
  readonly linkStates: EventStream<LinkState> = new Emitter<LinkState>().stream;
  readonly loadEarlier = undefined;
  readonly omp = new FakeOmp();
  readonly rpc = new RpcClient(this.omp, { deviceId: "test" });
  readonly companion = new CompanionClient(this.rpc);
  readonly dismissed: string[] = [];
  readonly pendingPrompts: (PendingPrompt | undefined)[] = [];
  private current: SessionView;
  private readonly emitter = new Emitter<SessionView>();

  constructor(
    view: SessionView = sessionView(),
    readonly companionHello: CompanionHello | undefined = undefined,
  ) {
    this.current = view;
  }

  /** Attaches the RPC client; call before any rpc or companion call. */
  async attach(): Promise<this> {
    await this.rpc.attach();
    return this;
  }

  emit(view: SessionView): void {
    this.current = view;
    this.emitter.add(view);
  }

  get view(): SessionView {
    return this.current;
  }

  get views(): EventStream<SessionView> {
    return this.emitter.stream;
  }

  dismissRequest(id: string): void {
    this.dismissed.push(id);
  }

  setPendingPrompt(prompt: PendingPrompt | undefined): void {
    this.pendingPrompts.push(prompt);
  }

  dismissNotice(): void {}

  reconnectNow(): void {}

  async detach(): Promise<void> {}

  async stop(): Promise<void> {}
}

/** Lets queued microtasks and timers of zero run, as the Dart tests' `_settle`. */
export async function settle(): Promise<void> {
  for (let i = 0; i < 10; i++) await Bun.sleep(0);
}
