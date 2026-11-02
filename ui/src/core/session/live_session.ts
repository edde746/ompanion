// Port of packages/omp_core/lib/src/session/live_session.dart.
import type { CompanionClient, CompanionHello } from "../companion/companion_client";
import type { RpcClient } from "../rpc/rpc_client";
import type { PendingPrompt, SessionView } from "../store/session_view";
import type { EventStream } from "../util/stream";

/**
 * One open omp session as the UI sees it: a live view plus the clients to command it.
 *
 * Created by `MachineRuntime.open` and `MachineRuntime.control`, which launch or attach the run, feed every frame
 * through the reducer, reconnect after link loss and resync the view. The UI never talks to transports directly.
 */
export interface LiveSession {
  /**
   * Identifies the run directory on the machine; stable across reconnects and devices. `control` for the machine's
   * control session, which has no run directory.
   */
  readonly runId: string;

  /**
   * Absolute session file path on the machine as omp reports it (`get_state.sessionFile`); omp writes the file with
   * the first message. Undefined for the control session (`--no-session`). Follows session switches inside the run
   * (`new_session`, `switch_session`, `branch`, fork, …).
   */
  readonly sessionPath: string | undefined;

  /** Host-native working directory omp runs in (`--cwd`). */
  readonly cwd: string;

  /** Current view. Replaced, never mutated; compare with `===`. */
  readonly view: SessionView;

  /** Emits every new [view]. Broadcast. */
  readonly views: EventStream<SessionView>;

  readonly linkState: LinkState;

  /** Emits every new [linkState]. Broadcast. */
  readonly linkStates: EventStream<LinkState>;

  /**
   * The RPC client of the current connection. After a reconnect this returns the new client, so read it at call time,
   * never cache it. Calls while [linkState] is not [LinkLive] throw `RpcClosedException`.
   */
  readonly rpc: RpcClient;

  /** Companion client of the current connection; same lifetime rules as [rpc]. */
  readonly companion: CompanionClient;

  /**
   * The companion's `hello` from the first attach: its version, verbs and events. Undefined when the process has no
   * companion; then every [companion] call would reach the model as a prompt, so never make one.
   */
  readonly companionHello: CompanionHello | undefined;

  /**
   * Loads the history before the earliest entry of [view] into it; undefined while [view] holds the whole history. A
   * large session file opens with its latest part only.
   */
  readonly loadEarlier: (() => Promise<void>) | undefined;

  /**
   * Closes request [id] in this device's view at once: after answering it here (every device also closes it when the
   * answer reaches `in.jsonl`), or for one-shot requests (`EditorTextRequest`, `OpenUrlRequest`) and dialogs whose
   * timeout passed.
   */
  dismissRequest(id: string): void;

  /**
   * Sets the prompt this device is sending ([SessionView.pendingPrompt]), so the chat shows it and its awaiting-reply
   * row from the send on; undefined clears it. The sender clears it when its prompt fails, finishes without a run, or
   * loses its connection; the reducer clears it at a run's first message and when a run ends.
   */
  setPendingPrompt(prompt: PendingPrompt | undefined): void;

  /** Removes toast [seq] from the view. */
  dismissNotice(seq: number): void;

  /** While [linkState] is [LinkReconnecting]: starts the next attempt now instead of at `nextTryAt`. */
  reconnectNow(): void;

  /**
   * Detaches this device. The omp process keeps running for other devices. The control session's process ends; the
   * next `MachineRuntime.control` starts a new one.
   */
  detach(): Promise<void>;

  /** Stops the omp process gracefully (EOF on its stdin), then detaches. */
  stop(): Promise<void>;
}

export type LinkState = LinkConnecting | LinkLive | LinkReconnecting | LinkClosed;

export interface LinkConnecting {
  readonly kind: "LinkConnecting";
}

export interface LinkLive {
  readonly kind: "LinkLive";
}

/** The link dropped; the runtime is retrying. [attempt] starts at 1; [nextTryAt] is when the next attempt starts. */
export interface LinkReconnecting {
  readonly kind: "LinkReconnecting";
  readonly attempt: number;
  readonly nextTryAt: number;
  readonly cause?: unknown;
}

/** Terminal: detached, stopped, the omp process exited, or reconnecting gave up (e.g. auth failed). */
export interface LinkClosed {
  readonly kind: "LinkClosed";
  readonly cause?: unknown;
  readonly exitCode?: number;
}

export const linkConnecting: LinkConnecting = { kind: "LinkConnecting" };
export const linkLive: LinkLive = { kind: "LinkLive" };
