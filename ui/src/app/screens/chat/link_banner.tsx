// Port of lib/screens/chat/link_banner.dart.
import type { JSX } from "@solidjs/web";
import { createSignal, Match, onSettled, Show, Switch } from "solid-js";
import type { LinkClosed, LinkReconnecting, LiveSession } from "../../../core/session/live_session";
import { useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import { linkState, sessionViewSelector } from "../../sessions/session_view_builder";
import { compactDuration } from "../../utils/compact_duration";
import { TextButton, TonalButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { resumeModelChooser } from "../config/model_picker";
import { describeConnectError } from "../machines/connect_dialogs";
import "./link_banner.css";

/**
 * The connection of `session` when it is not live: the retry countdown with "retry now" while reconnecting, and
 * "reopen" once the link is closed for good. Connecting shows in the header's state, where it moves nothing.
 */
export function LinkBanner(props: { readonly session: LiveSession }) {
  const link = linkState(() => props.session);
  const reconnecting = () => {
    const state = link();
    return state.kind === "LinkReconnecting" ? state : undefined;
  };
  const closed = () => {
    const state = link();
    return state.kind === "LinkClosed" ? state : undefined;
  };
  return (
    <Switch>
      <Match when={reconnecting()}>{(state) => <Reconnecting session={props.session} state={state()} />}</Match>
      <Match when={closed()}>{(state) => <Closed session={props.session} state={state()} />}</Match>
    </Switch>
  );
}

function Reconnecting(props: { readonly session: LiveSession; readonly state: LinkReconnecting }) {
  const [tick, setTick] = createSignal(0);
  onSettled(() => {
    const timer = setInterval(() => setTick((count) => count + 1), 1000);
    return () => clearInterval(timer);
  });
  const seconds = () => {
    tick();
    return Math.max(0, Math.ceil((props.state.nextTryAt - Date.now()) / 1000));
  };
  return (
    <Banner
      icon={Symbols.sync_problem}
      color="var(--warning)"
      text={t.chat.reconnecting({ attempt: props.state.attempt, seconds: seconds() })}
      detail={props.state.cause === undefined ? undefined : describeConnectError(props.state.cause)}
    >
      <TextButton onClick={() => props.session.reconnectNow()}>{t.chat.retryNow}</TextButton>
    </Banner>
  );
}

function Closed(props: { readonly session: LiveSession; readonly state: LinkClosed }) {
  const sessions = useSessions();
  const [reopening, setReopening] = createSignal(false);
  const idle = sessionViewSelector(
    () => props.session,
    (view) => view.idleExitMs,
  );

  async function reopen() {
    setReopening(true);
    try {
      await sessions.reopen(props.session, { chooseModel: resumeModelChooser(sessions) });
    } catch (error) {
      showSnackBar(t.chat.reopenFailed({ error: describeConnectError(error) }));
      setReopening(false);
    }
  }

  const text = () => {
    const idleMs = idle();
    if (idleMs !== undefined) return t.chat.idleExited({ duration: compactDuration(idleMs) });
    return props.state.exitCode === undefined ? t.chat.closed : t.chat.exited({ code: props.state.exitCode });
  };
  const detail = () => {
    if (idle() !== undefined) return t.chat.idleExitedDetail;
    return props.state.cause === undefined ? undefined : describeConnectError(props.state.cause);
  };
  return (
    <Banner
      icon={idle() === undefined ? Symbols.link_off : Symbols.bedtime}
      color={idle() === undefined ? "var(--error)" : "var(--on-surface-variant)"}
      text={text()}
      detail={detail()}
    >
      <TextButton onClick={() => void sessions.detach(props.session)}>{t.common.close}</TextButton>
      <TonalButton disabled={reopening()} onClick={() => void reopen()}>
        {t.chat.reopen}
      </TonalButton>
    </Banner>
  );
}

/** A flat strip under the header, its actions (`children`) at the end; only the icon carries the state's colour. */
function Banner(props: {
  readonly icon: string;
  readonly color: string;
  readonly text: string;
  readonly detail: string | undefined;
  readonly children: JSX.Element;
}) {
  return (
    <div class="link-banner">
      <span class="link-banner-icon" style={{ color: props.color }}>
        <Icon icon={props.icon} size={20} />
      </span>
      <div class="link-banner-texts">
        <span class="link-banner-text">{props.text}</span>
        <Show when={props.detail}>{(detail) => <span class="link-banner-detail">{detail()}</span>}</Show>
      </div>
      {props.children}
    </div>
  );
}
