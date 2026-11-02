// lib/screens/machines/connect_dialogs.dart: the dialogs a connection asks through (passwords, keyboard-interactive
// prompts, passphrases, host keys), and what a failed connection says.
import type { JSX } from "@solidjs/web";
import { createSignal, For, Show } from "solid-js";
import { OmpStartFailed } from "../../../core/session/run_session";
import { keyTypeLabel, sshPublicKeyFingerprint } from "../../../core/ssh/keys";
import {
  type HostKeyCheck,
  type KeyboardInteractiveRequest,
  type KeyPassphraseRequest,
  type SshKeyOffer,
  type SshOfferedKey,
  sshHopLabel,
} from "../../../core/ssh/ssh_config";
import { SshConnectException } from "../../../core/ssh/ssh_link";
import { type HostLink, HostLinkException } from "../../../core/transport/host_link";
import { deferred } from "../../../deferred";
import { t } from "../../i18n/i18n";
import type { HostKeyVerdict } from "../../models/host_key_trust";
import { type Machine, MissingCredential, sshEndpointLabel } from "../../models/machine";
import {
  ConnectCancelled,
  type ConnectPrompts,
  type MachineConnector,
  type PassphraseAnswer,
} from "../../services/machine_connector";
import { Checkbox } from "../../widgets/checkbox";
import { FilledButton, TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { LabeledField } from "../../widgets/labeled_field";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import type { PromptDialog, PromptDialogs } from "../shell/connect_prompt_pump";
import "./connect_dialogs.css";

/**
 * Opens a link to `machine` through `connector` with dialogs for passwords, keyboard-interactive prompts, passphrases
 * and host keys, runs `action` on it, and closes the link.
 */
export async function runOnMachine<T>(
  connector: MachineConnector,
  machine: Machine,
  action: (link: HostLink) => Promise<T>,
): Promise<T> {
  const link = await connector.open(machine, dialogConnectPrompts());
  try {
    return await action(link);
  } finally {
    await link.close();
  }
}

/** Prompts shown as dialogs over the app. */
export function dialogConnectPrompts(): ConnectPrompts {
  return {
    password: (hop) =>
      showDialog<string>((close) => <PasswordDialog hop={sshEndpointLabel(hop)} close={close} />),
    keyboardInteractive: (request) =>
      showDialog<string[]>((close) => <KeyboardInteractiveDialog request={request} close={close} />),
    hostKey: async (check, verdict) =>
      (await showDialog<boolean>((close) => <HostKeyDialog check={check} verdict={verdict} close={close} />, {
        dismissible: false,
      })) ?? false,
    passphrase: (request) =>
      showDialog<PassphraseAnswer>((close) => <PassphraseDialog request={request} close={close} />),
  };
}

/** Shows `build`'s dialog until the user closes it or {@link PromptDialog.close} does. */
function promptDialog<T>(build: (close: (value?: T) => void) => JSX.Element): PromptDialog<T> {
  const closed = deferred<void>();
  const answer = showDialog<T>((close) => {
    void closed.promise.then(() => close());
    return build(close);
  });
  return { answer, close: () => closed.resolve() };
}

/** The dialogs of the queued prompts ConnectPromptHost shows. */
export const promptDialogs: PromptDialogs = {
  password: (hop) => promptDialog((close) => <PasswordDialog hop={sshEndpointLabel(hop)} close={close} />),
  keyboardInteractive: (request) =>
    promptDialog((close) => <KeyboardInteractiveDialog request={request} close={close} />),
  hostKey: (check, verdict) => promptDialog((close) => <HostKeyDialog check={check} verdict={verdict} close={close} />),
  passphrase: (request) => promptDialog((close) => <PassphraseDialog request={request} close={close} />),
};

export function describeConnectError(error: unknown): string {
  if (error instanceof MissingCredential) {
    const hop = sshEndpointLabel(error.endpoint);
    switch (error.problem) {
      case "noKeySelected":
        return t.connectError.noKeySelected({ hop });
      case "keyMissing":
        return t.connectError.keyMissing({ hop });
      case "passwordMissing":
        return t.connectError.passwordMissing({ hop });
    }
  }
  if (error instanceof ConnectCancelled) return t.common.cancelled;
  if (error instanceof SshConnectException) {
    const { hop, offer } = error;
    if (error.failure === "authFailed" && offer !== undefined && offer.keys.length > 0) {
      return [
        describeRefusal(hop.host, offer),
        t.connectError.authorizedKeysHint({ user: hop.user, host: hop.host }),
      ].join("\n");
    }
    // The transport's line says where keys were looked for and why the agent had none.
    if (offer !== undefined && offer.keys.length === 0) {
      return [t.connectError.noKeys({ host: hop.host }), error.message].join("\n");
    }
    const label = sshHopLabel(hop);
    const what = {
      unreachable: t.connectError.unreachable,
      timeout: t.connectError.timeout,
      hostKeyRejected: t.connectError.hostKeyRejected,
      authFailed: t.connectError.authFailed,
      keyUnavailable: t.connectError.keyUnavailable,
      protocol: t.connectError.protocol,
    }[error.failure]({ hop: label });
    // The transport's own wording names the underlying cause, e.g. "Connection refused".
    return [what, error.message].join("\n");
  }
  if (error instanceof OmpStartFailed) {
    const model = error.unrestorableModel;
    if (model !== undefined) return t.sessions.modelUnavailable({ model });
  }
  // A HostLinkException's message already holds its cause, as the Dart's `'$message: $cause'`.
  if (error instanceof HostLinkException) return error.message;
  return error instanceof Error ? error.message : String(error);
}

/** Which keys `host` refused: `host.example.com did not accept the key 'id_work' (ED25519 SHA256:…).` */
export function describeRefusal(host: string, offer: SshKeyOffer): string {
  const keys = offer.keys;
  const [only] = keys;
  if (only !== undefined && keys.length === 1) return t.connectError.keyRefused({ host, key: keyLabel(only) });
  if (keys.every((key) => key.agent && key.path === undefined)) {
    return t.connectError.agentKeysRefused({ n: keys.length, host });
  }
  return [t.connectError.keysRefused({ host }), ...keys.map(keyLabel)].join("\n");
}

function keyLabel(key: SshOfferedKey): string {
  const comment = key.publicKey.comment;
  const what =
    key.name !== undefined
      ? `'${key.name}'`
      : key.path !== undefined
        ? key.path
        : key.agent
          ? comment === ""
            ? t.connectError.agentKeyUnnamed
            : t.connectError.agentKey({ comment })
          : comment === ""
            ? undefined
            : `'${comment}'`;
  const fingerprint = `${keyTypeLabel(key.publicKey.type)} ${sshPublicKeyFingerprint(key.publicKey)}`;
  return what === undefined ? fingerprint : `${what} (${fingerprint})`;
}

/** Trust-on-first-use prompt, host-key-change warning, or revocation notice. Closes with true to trust. */
export function HostKeyDialog(props: {
  readonly check: HostKeyCheck;
  readonly verdict: HostKeyVerdict;
  readonly close: (trusted?: boolean) => void;
}) {
  const host = () => (props.check.port === 22 ? props.check.host : `${props.check.host}:${props.check.port}`);
  const text = (): readonly [title: string, body: string] => {
    const verdict = props.verdict;
    switch (verdict.kind) {
      case "HostKeyUnknown":
      case "HostKeyTrusted":
        return [t.hostKey.unknownTitle, t.hostKey.unknownBody({ host: host() })];
      case "HostKeyChanged":
        return verdict.knownFingerprints.length === 0
          ? [t.hostKey.changedTitle, t.hostKey.changedOpenSshBody({ host: host() })]
          : [t.hostKey.changedTitle, t.hostKey.changedBody({ host: host() })];
      case "HostKeyOtherTypesKnown":
        return [t.hostKey.otherTypesTitle, t.hostKey.otherTypesBody({ host: host() })];
      case "HostKeyRevoked":
        return [t.hostKey.revokedTitle, t.hostKey.revokedBody({ host: host() })];
    }
  };
  const warning = () => props.verdict.kind !== "HostKeyUnknown";
  const knownFingerprints = () => (props.verdict.kind === "HostKeyChanged" ? props.verdict.knownFingerprints : []);
  const knownKeys = () => (props.verdict.kind === "HostKeyOtherTypesKnown" ? props.verdict.knownKeys : undefined);
  return (
    <Dialog
      icon={warning() ? Symbols.gpp_bad : Symbols.verified_user}
      iconColor={warning() ? "var(--error)" : undefined}
      title={text()[0]}
      actions={
        <Show
          when={props.verdict.kind !== "HostKeyRevoked"}
          fallback={<TextButton onClick={() => props.close(false)}>{t.common.close}</TextButton>}
        >
          <TextButton onClick={() => props.close(false)}>{t.common.cancel}</TextButton>
          <Show
            when={props.verdict.kind === "HostKeyUnknown" || props.verdict.kind === "HostKeyTrusted"}
            fallback={
              <TonalButton onClick={() => props.close(true)}>
                {props.verdict.kind === "HostKeyChanged" ? t.hostKey.replace : t.hostKey.trust}
              </TonalButton>
            }
          >
            <FilledButton onClick={() => props.close(true)}>{t.hostKey.trust}</FilledButton>
          </Show>
        </Show>
      }
    >
      <p>{text()[1]}</p>
      <span class="connect-dialogs-label connect-dialogs-first-label">{t.hostKey.keyType}</span>
      <span class="connect-dialogs-code">{props.check.keyType}</span>
      <span class="connect-dialogs-label">{t.hostKey.fingerprint}</span>
      <span class="connect-dialogs-code">{props.check.sha256Fingerprint}</span>
      <Show when={knownFingerprints().length > 0}>
        <span class="connect-dialogs-label">{t.hostKey.previouslyTrusted}</span>
        <For each={knownFingerprints()}>{(fingerprint) => <span class="connect-dialogs-code">{fingerprint}</span>}</For>
      </Show>
      <Show when={knownKeys()}>
        {(keys) => (
          <>
            <span class="connect-dialogs-label">{t.hostKey.knownToOpenSsh}</span>
            <For each={keys()}>
              {(key) => <span class="connect-dialogs-code">{`${key.type} ${sshPublicKeyFingerprint(key)}`}</span>}
            </For>
          </>
        )}
      </Show>
    </Dialog>
  );
}

/** Asks for `hop`'s password. Closes with it, or with nothing to cancel. */
export function PasswordDialog(props: { readonly hop: string; readonly close: (password?: string) => void }) {
  const [password, setPassword] = createSignal("");
  return (
    <Dialog
      title={t.prompt.passwordTitle({ hop: props.hop })}
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={() => props.close(password())}>{t.common.continueAction}</FilledButton>
        </>
      }
    >
      <LabeledField label={t.editor.password}>
        <TextField type="password" value={password()} onInput={setPassword} onSubmit={props.close} autofocus />
      </LabeledField>
    </Dialog>
  );
}

/**
 * Asks a keyboard-interactive `request`'s prompts, or the server's password after refused keys. Closes with the answers,
 * or with nothing to cancel.
 */
export function KeyboardInteractiveDialog(props: {
  readonly request: KeyboardInteractiveRequest;
  readonly close: (answers?: string[]) => void;
}) {
  const [answers, setAnswers] = createSignal<readonly string[]>(props.request.prompts.map(() => ""));
  const submit = () => props.close([...answers()]);
  const title = () => {
    const request = props.request;
    if (request.name !== "") return request.name;
    return request.password ? t.prompt.passwordTitle({ hop: request.hop }) : t.prompt.signInTitle({ hop: request.hop });
  };
  return (
    <Dialog
      title={title()}
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={submit}>{t.common.continueAction}</FilledButton>
        </>
      }
    >
      <div class="connect-dialogs-column">
        <Show when={props.request.refused}>
          {(refused) => (
            <p>
              {refused().keys.length === 0
                ? t.connectError.noKeys({ host: props.request.hop })
                : describeRefusal(props.request.hop, refused())}
            </p>
          )}
        </Show>
        <Show when={props.request.instruction !== ""}>
          <p>{props.request.instruction}</p>
        </Show>
        <For each={props.request.prompts} keyed={false}>
          {(prompt, index) => (
            <LabeledField label={prompt().text.trim()}>
              <TextField
                type={prompt().echo ? "text" : "password"}
                value={answers()[index] ?? ""}
                onInput={(value) => setAnswers((list) => list.map((answer, at) => (at === index ? value : answer)))}
                onSubmit={index === props.request.prompts.length - 1 ? submit : undefined}
                autofocus={index === 0}
              />
            </LabeledField>
          )}
        </For>
      </div>
    </Dialog>
  );
}

/**
 * Asks for the passphrase of an encrypted identity file from `~/.ssh/config`. Closes with it and whether to keep it in
 * secure storage, or with nothing to cancel.
 */
export function PassphraseDialog(props: {
  readonly request: KeyPassphraseRequest;
  readonly close: (answer?: PassphraseAnswer) => void;
}) {
  const [passphrase, setPassphrase] = createSignal("");
  const [remember, setRemember] = createSignal(false);
  const submit = () => props.close({ passphrase: passphrase(), remember: remember() });
  return (
    <Dialog
      title={t.prompt.passphraseTitle({ path: props.request.path })}
      actions={
        <>
          <TextButton onClick={() => props.close()}>{t.common.cancel}</TextButton>
          <FilledButton onClick={submit}>{t.common.continueAction}</FilledButton>
        </>
      }
    >
      <div class="connect-dialogs-column">
        <div>
          <p>
            {props.request.publicKey === undefined
              ? t.prompt.passphraseUnknownKey({ hop: props.request.hop })
              : t.prompt.passphraseAccepted({ hop: props.request.hop })}
          </p>
          <Show when={props.request.publicKey}>
            {(key) => (
              <span class="connect-dialogs-code connect-dialogs-key">
                {`${keyTypeLabel(key().type)} ${sshPublicKeyFingerprint(key())}`}
              </span>
            )}
          </Show>
        </div>
        <LabeledField label={t.prompt.passphrase} error={props.request.wrong ? t.prompt.passphraseWrong : undefined}>
          <TextField type="password" value={passphrase()} onInput={setPassphrase} onSubmit={submit} autofocus />
        </LabeledField>
        {/* Without a public key there is no fingerprint to keep the passphrase under. */}
        <Show when={props.request.publicKey !== undefined}>
          <label class="connect-dialogs-check">
            <Checkbox value={remember()} onChanged={setRemember} />
            <span>{t.prompt.rememberPassphrase}</span>
          </label>
        </Show>
      </div>
    </Dialog>
  );
}
