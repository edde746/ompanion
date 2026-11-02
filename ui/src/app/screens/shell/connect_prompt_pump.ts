// The order lib/screens/shell/connect_prompt_host.dart shows the connection prompts in: one at a time, oldest first,
// only while the app is in front; each answered through its dialog, or closed when it is settled elsewhere.
import type { HostKeyCheck, KeyboardInteractiveRequest, KeyPassphraseRequest } from "../../../core/ssh/ssh_config";
import type { HostKeyVerdict } from "../../models/host_key_trust";
import type { SshEndpoint } from "../../models/machine";
import type { ConnectPromptQueue, PendingPrompt } from "../../sessions/connect_prompt_queue";
import type { PassphraseAnswer } from "../../services/machine_connector";

/** A shown prompt dialog. */
export interface PromptDialog<T> {
  /** What the user answered; undefined when dismissed or closed. */
  readonly answer: Promise<T | undefined>;
  close(): void;
}

/** Shows each kind of prompt's dialog. */
export interface PromptDialogs {
  password(hop: SshEndpoint): PromptDialog<string>;
  keyboardInteractive(request: KeyboardInteractiveRequest): PromptDialog<string[]>;
  hostKey(check: HostKeyCheck, verdict: HostKeyVerdict): PromptDialog<boolean>;
  passphrase(request: KeyPassphraseRequest): PromptDialog<PassphraseAnswer>;
}

/**
 * Shows `queue`'s prompts through `dialogs` while `foreground()` holds. {@link pump} after the queue or the foreground
 * changed.
 */
export class ConnectPromptPump {
  private showing: PendingPrompt | undefined;

  constructor(
    private readonly queue: ConnectPromptQueue,
    private readonly dialogs: PromptDialogs,
    private readonly foreground: () => boolean,
  ) {}

  /** Shows the next prompt unless one shows or the app is in the background. */
  pump(): void {
    if (this.showing !== undefined || !this.foreground()) return;
    const prompt = this.queue.next();
    if (prompt === undefined) return;
    this.showing = prompt;
    void this.show(prompt);
  }

  private async show(prompt: PendingPrompt): Promise<void> {
    try {
      switch (prompt.kind) {
        case "PendingPassword":
          prompt.complete(await this.until(prompt, this.dialogs.password(prompt.hop)));
          break;
        case "PendingKeyboardInteractive":
          prompt.complete(await this.until(prompt, this.dialogs.keyboardInteractive(prompt.request)));
          break;
        case "PendingHostKey":
          // Dismissing is declining: the connection attempt fails instead of trusting an unchecked key.
          prompt.complete((await this.until(prompt, this.dialogs.hostKey(prompt.check, prompt.verdict))) ?? false);
          break;
        case "PendingPassphrase":
          prompt.complete(await this.until(prompt, this.dialogs.passphrase(prompt.request)));
          break;
      }
    } finally {
      // A dialog that could not be shown fails its connection attempt rather than leaving it hanging.
      prompt.cancel();
      this.queue.remove(prompt);
      this.showing = undefined;
      this.pump();
    }
  }

  /**
   * The answer of `dialog`, which closes once `prompt` is settled elsewhere (its machine was deleted, or a retry asked
   * the same question again): an answer there would be dropped.
   */
  private until<T>(prompt: PendingPrompt, dialog: PromptDialog<T>): Promise<T | undefined> {
    void prompt.settled.then(() => dialog.close());
    return dialog.answer;
  }
}
