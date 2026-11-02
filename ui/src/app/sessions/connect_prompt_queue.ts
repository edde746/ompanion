// lib/sessions/connect_prompt_queue.dart: the questions connection attempts wait on, shown one at a time.
import { type Accessor, createSignal, type Setter } from "solid-js";
import type { HostKeyCheck, KeyboardInteractiveRequest, KeyPassphraseRequest } from "../../core/ssh/ssh_config";
import { type Deferred, deferred } from "../../deferred";
import type { HostKeyVerdict } from "../models/host_key_trust";
import type { Machine, SshEndpoint } from "../models/machine";
import type { ConnectPrompts, PassphraseAnswer } from "../services/machine_connector";

/** One question; resolving its answer resumes the attempt. */
abstract class Pending<T> {
  private readonly answer: Deferred<T> = deferred<T>();
  private done = false;

  constructor(
    readonly machine: Machine,
    private readonly cancelled: T,
  ) {}

  get answered(): boolean {
    return this.done;
  }

  /** Resolves once the prompt is answered or cancelled. */
  get settled(): Promise<T> {
    return this.answer.promise;
  }

  complete(value: T): void {
    if (this.done) return;
    this.done = true;
    this.answer.resolve(value);
  }

  /** Gives up on the prompt: the connection attempt fails as if the user dismissed it. */
  cancel(): void {
    this.complete(this.cancelled);
  }
}

export class PendingPassword extends Pending<string | undefined> {
  readonly kind = "PendingPassword";

  constructor(
    machine: Machine,
    readonly hop: SshEndpoint,
  ) {
    super(machine, undefined);
  }
}

export class PendingKeyboardInteractive extends Pending<string[] | undefined> {
  readonly kind = "PendingKeyboardInteractive";

  constructor(
    machine: Machine,
    readonly request: KeyboardInteractiveRequest,
  ) {
    super(machine, undefined);
  }
}

export class PendingHostKey extends Pending<boolean> {
  readonly kind = "PendingHostKey";

  constructor(
    machine: Machine,
    readonly check: HostKeyCheck,
    readonly verdict: HostKeyVerdict,
  ) {
    super(machine, false);
  }
}

export class PendingPassphrase extends Pending<PassphraseAnswer | undefined> {
  readonly kind = "PendingPassphrase";

  constructor(
    machine: Machine,
    readonly request: KeyPassphraseRequest,
  ) {
    super(machine, undefined);
  }
}

/** A question a connection attempt waits on. Completing it resumes the attempt. */
export type PendingPrompt = PendingPassword | PendingKeyboardInteractive | PendingHostKey | PendingPassphrase;

/**
 * Connection prompts of every machine runtime, from foreground connects and background reconnects alike. A reconnect
 * can need a password or a host-key decision while the app is in the background or the user is looking at another
 * machine, so prompts wait here, oldest first, until the prompt host shows them one at a time while the app is in the
 * foreground.
 */
export class ConnectPromptQueue {
  private readonly changed: Accessor<number>;
  private readonly setChanged: Setter<number>;
  private readonly pending: PendingPrompt[] = [];

  constructor() {
    [this.changed, this.setChanged] = createSignal(0, { ownedWrite: true });
  }

  /** The prompt to show next, or undefined. Tracks. */
  next(): PendingPrompt | undefined {
    this.changed();
    return this.pending[0];
  }

  /** Prompts for connections to `machine` that queue here. */
  promptsFor(machine: Machine): ConnectPrompts {
    return {
      password: (hop) => this.enqueue(new PendingPassword(machine, hop)).settled,
      keyboardInteractive: (request) => this.enqueue(new PendingKeyboardInteractive(machine, request)).settled,
      hostKey: (check, verdict) => this.enqueue(new PendingHostKey(machine, check, verdict)).settled,
      passphrase: (request) => this.enqueue(new PendingPassphrase(machine, request)).settled,
    };
  }

  /** Removes `prompt` once the host completed it. */
  remove(prompt: PendingPrompt): void {
    const index = this.pending.indexOf(prompt);
    if (index < 0) return;
    this.pending.splice(index, 1);
    this.notify();
  }

  /** Cancels every prompt of `machineId`, e.g. when the machine was deleted. */
  cancelFor(machineId: string): void {
    const dropped = this.pending.filter((prompt) => prompt.machine.id === machineId);
    if (dropped.length === 0) return;
    for (const prompt of dropped) {
      prompt.cancel();
      this.pending.splice(this.pending.indexOf(prompt), 1);
    }
    this.notify();
  }

  /** Cancels every prompt. */
  dispose(): void {
    for (const prompt of this.pending.splice(0)) prompt.cancel();
    this.notify();
  }

  private enqueue<T extends PendingPrompt>(prompt: T): T {
    // A retrying reconnect asks again for the same hop; the attempt that asked first has given up by then, so its
    // prompt is dropped rather than shown twice.
    for (const old of this.pending.filter((pending) => sameQuestion(pending, prompt))) {
      old.cancel();
      this.pending.splice(this.pending.indexOf(old), 1);
    }
    this.pending.push(prompt);
    this.notify();
    return prompt;
  }

  private notify(): void {
    this.setChanged((count) => count + 1);
  }
}

function sameQuestion(a: PendingPrompt, b: PendingPrompt): boolean {
  if (a.machine.id !== b.machine.id) return false;
  if (a.kind === "PendingPassword" && b.kind === "PendingPassword") return a.hop.id === b.hop.id;
  if (a.kind === "PendingKeyboardInteractive" && b.kind === "PendingKeyboardInteractive") return true;
  if (a.kind === "PendingHostKey" && b.kind === "PendingHostKey") {
    return a.check.host === b.check.host && a.check.port === b.check.port;
  }
  if (a.kind === "PendingPassphrase" && b.kind === "PendingPassphrase") {
    return a.request.hop === b.request.hop && a.request.path === b.request.path;
  }
  return false;
}
