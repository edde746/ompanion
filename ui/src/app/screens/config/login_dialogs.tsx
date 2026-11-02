// Port of lib/screens/config/login_dialogs.dart. The dialog's state is RpcLogin (rpc_login.ts).
import { createSignal, For, Match, onSettled, Show, Switch } from "solid-js";
import { call } from "../../../bridge";
import type { LiveSession } from "../../../core/session/live_session";
import type { OpenUrlRequest } from "../../../core/store/session_view";
import type { ConfigTarget } from "../../config/config_target";
import { t } from "../../i18n/i18n";
import { onBack } from "../../platform";
import { appLogger } from "../../utils/app_logger";
import { ActivityMark } from "../../widgets/activity_mark";
import { FilledButton, TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { isWebLink, openWebLink } from "../external_links";
import { errorText, runReporting } from "./config_widgets";
import { type LoginQuestion, RpcLogin } from "./rpc_login";
import "./login_dialogs.css";

/** Opens omp's authorization link in the browser when it is a web link; the link block says why when it is not. */
async function openInBrowser(url: string): Promise<void> {
  if (!(await openWebLink(url))) appLogger.w(`not opening a login link that is not a web link: ${url}`);
}

interface LoginOptions {
  readonly target: ConfigTarget;
  readonly control: LiveSession;
  readonly providerId: string;
  readonly providerName: string;
}

/** Runs omp's RPC `login` for a provider in a dialog; resolves once the dialog closed. */
export async function showRpcLogin(options: LoginOptions): Promise<void> {
  await showDialog<void>((close) => <RpcLoginDialog {...options} close={close} />, { dismissible: false });
}

function RpcLoginDialog(props: LoginOptions & { readonly close: () => void }) {
  const login = new RpcLogin({
    target: props.target,
    control: props.control,
    providerId: props.providerId,
    openBrowser: openInBrowser,
  });
  const [input, setInput] = createSignal("");
  let closing = false;
  const pending = () => !login.done() && login.error() === undefined;

  // System back and Escape end the login as Cancel does; the dialog host's own back and Escape do nothing for a dialog
  // that is not dismissible.
  const cancel = async () => {
    if (closing) return;
    closing = true;
    await runReporting(() => login.cancel());
    props.close();
  };

  const answer = (request: LoginQuestion, reply: { value?: string; confirmed?: boolean }) =>
    runReporting(
      async () => {
        await login.answer(request, reply);
        setInput("");
      },
      { secret: true },
    );

  onSettled(() => {
    login.start();
    const removeBack = onBack(() => void cancel());
    return () => {
      removeBack();
      void login.close();
    };
  });

  return (
    <div
      class="login-dialogs-keys"
      onKeyDown={(event) => {
        if (event.key !== "Escape") return;
        event.preventDefault();
        void cancel();
      }}
    >
      <Dialog
        class="login-dialogs"
        title={t.config.accounts.loginTitle({ provider: props.providerName })}
        actions={
          <Show
            when={pending()}
            fallback={<FilledButton onClick={() => props.close()}>{t.common.close}</FilledButton>}
          >
            <TextButton onClick={() => void cancel()}>{t.common.cancel}</TextButton>
          </Show>
        }
      >
        <Show when={login.link() === undefined && pending()}>
          <div class="login-dialogs-waiting">
            <ActivityMark size={18} />
            <span>{t.config.accounts.waitingForLink}</span>
          </div>
        </Show>
        <Show when={login.link()}>{(link) => <LinkBlock link={link()} login={login} />}</Show>
        <For each={login.notices()}>{(notice) => <p class="login-dialogs-notice">{notice}</p>}</For>
        <Show when={pending() ? login.question() : undefined}>
          {(question) => (
            <Question request={question()} input={input()} onInput={setInput} onAnswer={answer} />
          )}
        </Show>
        <Show when={login.done()}>
          <p class="login-dialogs-done">{t.config.accounts.loggedIn}</p>
        </Show>
        <Show when={login.error() !== undefined}>
          <p class="login-dialogs-error">{errorText(login.error())}</p>
        </Show>
      </Dialog>
    </div>
  );
}

/** The authorization link, the forwarded callback ports, and buttons to open or copy it. */
function LinkBlock(props: { readonly link: OpenUrlRequest; readonly login: RpcLogin }) {
  const web = () => isWebLink(props.link.url);
  return (
    <div class="login-dialogs-link">
      <p>{t.config.accounts.openLink}</p>
      {/* One line: the link is long and opaque; Copy link takes all of it. */}
      <p class="login-dialogs-url">{props.link.url}</p>
      <div class="login-dialogs-buttons">
        <FilledButton
          icon={Symbols.open_in_browser}
          disabled={!web()}
          onClick={() => void openInBrowser(props.link.url)}
        >
          {t.config.accounts.openBrowser}
        </FilledButton>
        <TonalButton
          icon={Symbols.content_copy}
          onClick={() => void call("shell.clipboardWrite", { text: props.link.launchUrl ?? props.link.url })}
        >
          {t.config.accounts.copyLink}
        </TonalButton>
      </div>
      <Show when={!web()}>
        <p class="login-dialogs-small login-dialogs-failure">{t.requests.notWebLink}</p>
      </Show>
      <Show when={props.link.instructions}>{(text) => <p>{text()}</p>}</Show>
      <Show when={props.login.forwarding().length > 0}>
        <p class="login-dialogs-small">
          {t.config.accounts.forwarding({ ports: props.login.forwarding().join(", ") })}
        </p>
      </Show>
      <For each={[...props.login.forwardFailures()]}>
        {([port, error]) => (
          <p class="login-dialogs-small login-dialogs-failure">
            {t.config.accounts.forwardFailed({ port: String(port), error: errorText(error) })}
          </p>
        )}
      </For>
    </div>
  );
}

/** A question omp asks during login: a code or URL to paste, a choice, or a yes/no. */
function Question(props: {
  readonly request: LoginQuestion;
  readonly input: string;
  readonly onInput: (value: string) => void;
  readonly onAnswer: (request: LoginQuestion, reply: { value?: string; confirmed?: boolean }) => void;
}) {
  return (
    <div class="login-dialogs-question">
      <Switch>
        <Match when={props.request.kind === "InputRequest" ? props.request : undefined}>
          {(request) => {
            let field: HTMLInputElement | undefined;
            // The field comes after the dialog opened, so the dialog's own first focus missed it.
            onSettled(() => field?.focus());
            return (
              <>
                <p>{request().title}</p>
                <div class="login-dialogs-row">
                  <TextField
                    class="login-dialogs-input"
                    value={props.input}
                    onInput={props.onInput}
                    onSubmit={(value) => props.onAnswer(request(), { value })}
                    hint={request().placeholder}
                    ref={(element) => {
                      field = element;
                    }}
                  />
                  <FilledButton onClick={() => props.onAnswer(request(), { value: props.input })}>
                    {t.config.accounts.submit}
                  </FilledButton>
                </div>
              </>
            );
          }}
        </Match>
        <Match when={props.request.kind === "SelectRequest" ? props.request : undefined}>
          {(request) => (
            <>
              <p>{request().title}</p>
              <div class="login-dialogs-buttons">
                <For each={request().options}>
                  {(option) => (
                    <TonalButton onClick={() => props.onAnswer(request(), { value: option })}>{option}</TonalButton>
                  )}
                </For>
              </div>
            </>
          )}
        </Match>
        <Match when={props.request.kind === "ConfirmRequest" ? props.request : undefined}>
          {(request) => (
            <>
              <p class="login-dialogs-question-title">{request().title}</p>
              <p>{request().message}</p>
              <div class="login-dialogs-buttons">
                <FilledButton onClick={() => props.onAnswer(request(), { confirmed: true })}>
                  {t.config.accounts.yes}
                </FilledButton>
                <TonalButton onClick={() => props.onAnswer(request(), { confirmed: false })}>
                  {t.config.accounts.no}
                </TonalButton>
              </div>
            </>
          )}
        </Match>
      </Switch>
    </div>
  );
}
