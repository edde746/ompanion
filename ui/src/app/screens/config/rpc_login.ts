// The state of lib/screens/config/login_dialogs.dart's RpcLoginDialog without its widgets (login_dialogs.tsx), so a
// test drives it without a DOM: the forwarded callback ports, the authorization link, omp's question, done or failed,
// and cancel.
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import type { LocalForward, MachineRuntime } from "../../../core/session/machine_runtime";
import type {
  ConfirmRequest,
  InputRequest,
  OpenUrlRequest,
  SelectRequest,
  SessionView,
} from "../../../core/store/session_view";
import type { Subscription } from "../../../core/util/stream";
import { loopbackPorts } from "../../config/login";
import { appLogger } from "../../utils/app_logger";

/** What a login uses of its ConfigTarget. */
export interface LoginTarget {
  readonly isThisComputer: boolean;
  readonly runtime: Pick<MachineRuntime, "forwardLocal">;
}

/** A question omp asks during login: a code or URL to paste, a choice, or a yes/no. */
export type LoginQuestion = InputRequest | SelectRequest | ConfirmRequest;

function questionOf(view: SessionView): LoginQuestion | undefined {
  return view.requests.find(
    (request): request is LoginQuestion =>
      request.kind === "InputRequest" || request.kind === "SelectRequest" || request.kind === "ConfirmRequest",
  );
}

/**
 * RPC `login` in the control process: omp sends `open_url` with the authorization link, then `input` for a pasted code
 * or redirect URL when the provider needs one; the call completes once the credential is stored.
 *
 * On a remote machine the link's loopback callback ports are forwarded from this device, so the browser's redirect
 * reaches omp's callback server there.
 */
export class RpcLogin {
  /** The control session's view, as of the last change. */
  readonly view: Accessor<SessionView>;
  /** omp's authorization link, once it sent one. */
  readonly link: Accessor<OpenUrlRequest | undefined>;
  /** The credential is stored. */
  readonly done: Accessor<boolean>;
  /** Why `login` failed; undefined while it has not. */
  readonly error: Accessor<unknown>;
  /** The callback ports forwarded to the machine, ascending. */
  readonly forwarding: Accessor<readonly number[]>;
  /** The callback ports that could not be forwarded, and why. */
  readonly forwardFailures: Accessor<ReadonlyMap<number, unknown>>;
  private readonly setView: Setter<SessionView>;
  private readonly setLink: Setter<OpenUrlRequest | undefined>;
  private readonly setDone: Setter<boolean>;
  private readonly setError: Setter<unknown>;
  private readonly setForwarding: Setter<readonly number[]>;
  private readonly setForwardFailures: Setter<ReadonlyMap<number, unknown>>;
  private readonly target: LoginTarget;
  private readonly control: LiveSession;
  private readonly providerId: string;
  private readonly openBrowser: (url: string) => Promise<void>;
  /** Notices from this sequence number on came after the login started. */
  private readonly firstNotice: number;
  private readonly forwards = new Map<number, LocalForward>();
  private readonly failures = new Map<number, unknown>();
  private readonly handled = new Set<string>();
  private views: Subscription | undefined;
  private closed = false;

  constructor(options: {
    target: LoginTarget;
    control: LiveSession;
    providerId: string;
    /** Opens the authorization link once omp sent it. */
    openBrowser: (url: string) => Promise<void>;
  }) {
    this.target = options.target;
    this.control = options.control;
    this.providerId = options.providerId;
    this.openBrowser = options.openBrowser;
    this.firstNotice = options.control.view.nextSeq;
    [this.view, this.setView] = createSignal(options.control.view);
    [this.link, this.setLink] = createSignal<OpenUrlRequest | undefined>(undefined);
    [this.done, this.setDone] = createSignal(false);
    [this.error, this.setError] = createSignal<unknown>(undefined);
    [this.forwarding, this.setForwarding] = createSignal<readonly number[]>([]);
    [this.forwardFailures, this.setForwardFailures] = createSignal<ReadonlyMap<number, unknown>>(new Map());
  }

  /** Watches the control view and starts omp's `login`. */
  start(): void {
    this.views = this.control.views.listen(() => this.onView());
    // A link omp sent before the login started.
    this.onView();
    void this.control.rpc.login(this.providerId).then(
      () => {
        if (!this.closed) this.setDone(true);
      },
      (error: unknown) => {
        if (!this.closed) this.setError(() => error);
      },
    );
  }

  /** omp's open question, while there is one. */
  question(): LoginQuestion | undefined {
    return questionOf(this.view());
  }

  /** What omp said since the login started. */
  notices(): string[] {
    return this.view().notices.flatMap((notice) =>
      notice.kind === "MessageNotice" && notice.seq >= this.firstNotice ? [notice.message] : [],
    );
  }

  async answer(request: LoginQuestion, answer: { value?: string; confirmed?: boolean }): Promise<void> {
    await this.control.rpc.respondToUi(request.id, answer);
    this.control.dismissRequest(request.id);
  }

  /**
   * Ends a login that has neither finished nor failed. The dialog's Cancel, system back and Escape all go through
   * here: closing the dialog alone would leave omp's `login` blocking the control process's command queue.
   */
  async cancel(): Promise<void> {
    const question = questionOf(this.control.view);
    if (this.done() || this.error() !== undefined) return;
    try {
      if (question !== undefined) {
        await this.control.rpc.respondToUi(question.id, { cancelled: true });
        this.control.dismissRequest(question.id);
      }
    } finally {
      // Measured with openai-codex: after its paste prompt is cancelled omp still waits for the browser's callback,
      // RPC has no command to stop a login, and the control process stops answering prompts. End it, also when the
      // question could not be cancelled; the next page load starts a new one.
      await this.control.detach();
    }
  }

  /** Stops watching the view and closes the forwards. */
  async close(): Promise<void> {
    this.closed = true;
    this.views?.cancel();
    const forwards = [...this.forwards.values()];
    this.forwards.clear();
    for (const forward of forwards) await forward.close();
  }

  private onView(): void {
    for (const request of this.control.view.requests) {
      if (request.kind !== "OpenUrlRequest" || this.handled.has(request.id)) continue;
      this.handled.add(request.id);
      // One-shot: the login keeps the link, the view drops the request.
      this.control.dismissRequest(request.id);
      void this.openLink(request);
    }
    this.setView(this.control.view);
  }

  private async openLink(request: OpenUrlRequest): Promise<void> {
    await this.forward(loopbackPorts(request.url, request.launchUrl));
    if (this.closed) return;
    this.setLink(request);
    await this.openBrowser(request.url);
  }

  /** Nothing to do for this computer, where omp's callback server already listens. */
  private async forward(ports: ReadonlySet<number>): Promise<void> {
    if (this.target.isThisComputer) return;
    for (const port of ports) {
      if (this.forwards.has(port) || this.failures.has(port)) continue;
      let forward: LocalForward;
      try {
        forward = await this.target.runtime.forwardLocal(port, { localPort: port });
      } catch (error) {
        // The port is busy here: the browser cannot reach omp; the pasted redirect URL still works.
        this.failures.set(port, error);
        this.setForwardFailures(new Map(this.failures));
        appLogger.w(`forwarding OAuth callback port ${port} failed`, { error });
        continue;
      }
      if (this.closed) {
        await forward.close();
        return;
      }
      this.forwards.set(port, forward);
      this.setForwarding([...this.forwards.keys()].sort((a, b) => a - b));
    }
  }
}
