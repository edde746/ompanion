// Port of lib/screens/chat/request_panel.dart. Its decisions live in requests.ts.
import type { JSX } from "@solidjs/web";
import { createEffect, createMemo, createSignal, For, onSettled, Show, untrack } from "solid-js";
import { call } from "../../../bridge";
import type { LiveSession } from "../../../core/session/live_session";
import type { ApprovalRequest, UiRequest } from "../../../core/store/session_view";
import { useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import { isTouch } from "../../platform";
import { sessionViewSelector } from "../../sessions/session_view_builder";
import { FilledButton, IconButton, TextButton, TonalButton } from "../../widgets/button";
import * as Symbols from "../../widgets/symbols";
import { TextField } from "../../widgets/text_field";
import { isWebLink, openWebLink } from "../external_links";
import { AskForm } from "./ask_form";
import { RequestFrame } from "./request_frame";
import "./request_panel.css";
import {
  approvalShown,
  followRequests,
  isApproveOption,
  noShownRequests,
  type RequestDraft,
  requestDraft,
  requestTitle,
  type ShownRequests,
  showRequest,
  updateComposer,
} from "./requests";
import "./transcript/code_style.css";

/**
 * `session`'s open requests, inline above the composer: one in full, with its position, previous and next when several
 * are open. Nothing here is modal; the transcript, the composer and the rest of the app stay usable.
 *
 * A request leaves the panel when it leaves the view: answered here, answered by another device, cancelled by omp,
 * settled by the companion, or timed out. `set_editor_text` fills the composer instead.
 */
export function RequestPanel(props: { readonly session: LiveSession }) {
  const sessions = useSessions();
  // The reducer keeps an unchanged request list identical; most views are streamed tokens.
  const requests = sessionViewSelector(
    () => props.session,
    (view) => view.requests,
  );
  const [shown, setShown] = createSignal<ShownRequests>(noShownRequests);
  // What the effect and the navigation build on: `shown()` returns its last committed value until the next flush.
  let current = noShownRequests;
  let followed: LiveSession | undefined;
  /** What the user entered into each open request, so one navigated away from comes back as it was left. */
  const drafts = new Map<string, RequestDraft>();
  createEffect(
    () => ({ session: props.session, requests: requests() }),
    (next) => {
      if (next.session !== followed) {
        followed = next.session;
        current = noShownRequests;
        drafts.clear();
      }
      const hadRequests = current.requests.length > 0;
      current = followRequests(current, next.requests);
      for (const id of drafts.keys()) {
        if (!current.requests.some((request) => request.id === id)) drafts.delete(id);
      }
      setShown(current);
      updateComposer(next.session, sessions, next.requests, hadRequests);
    },
  );
  const show = (index: number) => {
    current = showRequest(current, index);
    setShown(current);
  };
  // Request objects never change while their id is open, so a new object is a new request (Dart's ValueKey(id)).
  const request = createMemo(() => shown().requests[shown().index]);
  return (
    <Show when={request()} keyed>
      {(request) => {
        let draft = drafts.get(request.id);
        if (draft === undefined) drafts.set(request.id, (draft = requestDraft(request)));
        return (
          <div class="request-panel">
            <RequestContent
              session={props.session}
              request={request}
              draft={draft}
              deadlineMs={sessions.deadlinesOf(props.session).of(request.id)}
              navigation={
                shown().requests.length < 2 ? undefined : (
                  <Navigation index={shown().index} count={shown().requests.length} onShow={show} />
                )
              }
            />
          </div>
        );
      }}
    </Show>
  );
}

function Navigation(props: { readonly index: number; readonly count: number; readonly onShow: (index: number) => void }) {
  const size = isTouch() ? 36 : 32;
  return (
    <div class="request-panel-navigation">
      <IconButton
        icon={Symbols.chevron_left}
        tooltip={t.requests.previous}
        size={size}
        disabled={props.index === 0}
        onClick={() => props.onShow(props.index - 1)}
      />
      <span class="request-panel-position">
        {t.requests.position({ index: props.index + 1, count: props.count })}
      </span>
      <IconButton
        icon={Symbols.chevron_right}
        tooltip={t.requests.next}
        size={size}
        disabled={props.index === props.count - 1}
        onClick={() => props.onShow(props.index + 1)}
      />
    </div>
  );
}

/**
 * One request, inline. Answers go out through `session`; the request then leaves the view and the panel. Mounted once
 * per request, so the session, the request and its draft stay the same for its life.
 */
function RequestContent(props: {
  readonly session: LiveSession;
  readonly request: UiRequest;
  /** What the user entered so far; edits land here. */
  readonly draft: RequestDraft;
  /** Epoch ms at which omp stops waiting for the answer. */
  readonly deadlineMs?: number;
  readonly navigation?: JSX.Element;
}) {
  const sessions = useSessions();
  const session = untrack(() => props.session);
  const request = untrack(() => props.request);
  const draft = untrack(() => props.draft);
  const [text, setText] = createSignal(draft.text);
  const [busy, setBusy] = createSignal(false);
  const [error, setError] = createSignal<string>();
  const [forwardNote, setForwardNote] = createSignal<string>();
  const edit = (value: string) => {
    draft.text = value;
    setText(value);
  };

  /** Sends an answer, then closes the request in this device's view. */
  const answer = async (send: () => Promise<void>) => {
    setBusy(true);
    setError(undefined);
    try {
      await send();
      session.dismissRequest(request.id);
    } catch (failure) {
      setBusy(false);
      setError(t.requests.answerFailed({ error: String(failure) }));
    }
  };
  const respond = (reply: { value?: string; confirmed?: boolean; cancelled?: boolean }) =>
    void answer(() => session.rpc.respondToUi(request.id, reply));

  if (request.kind === "OpenUrlRequest") {
    onSettled(() => {
      const machine = sessions.machineOf(session);
      if (machine === undefined) return;
      sessions.forwardOAuthCallback(machine, request.url).then(
        (forward) => {
          if (forward !== undefined) setForwardNote(t.requests.forwarding({ port: forward.localPort }));
        },
        (failure: unknown) => setError(t.requests.forwardFailed({ error: String(failure) })),
      );
    });
  }

  const frame = (body: JSX.Element, actions: JSX.Element) => (
    <RequestFrame
      title={request.kind === "CompanionRequest" ? t.requests.unsupportedTitle : requestTitle(request)}
      navigation={props.navigation}
      deadlineMs={props.deadlineMs}
      error={error()}
      actions={actions}
    >
      {body}
    </RequestFrame>
  );
  const cancel = () => (
    <TextButton disabled={busy()} onClick={() => respond({ cancelled: true })}>
      {t.common.cancel}
    </TextButton>
  );
  const submit = () => (
    <FilledButton disabled={busy()} onClick={() => respond({ value: draft.text })}>
      {t.requests.submit}
    </FilledButton>
  );

  switch (request.kind) {
    case "ApprovalRequest": {
      // omp lists the narrowest approval first (`Approve`, `Approve Once`); the wider grants after it (for the session,
      // a file, a directory) stay tonal, so the one filled button is the one that approves this call alone.
      const primary = request.options.find(isApproveOption);
      return frame(
        <ApprovalBody session={session} request={request} />,
        <For each={request.options}>
          {(option) =>
            option === primary ? (
              <FilledButton disabled={busy()} onClick={() => respond({ value: option })}>
                {option}
              </FilledButton>
            ) : (
              <TonalButton disabled={busy()} onClick={() => respond({ value: option })}>
                {option}
              </TonalButton>
            )
          }
        </For>,
      );
    }
    case "SelectRequest":
      return frame(
        <div class="request-panel-options">
          <For each={request.options}>
            {(option, index) => (
              <button
                type="button"
                data-ripple
                class={[
                  "request-panel-option",
                  {
                    "request-panel-option-touch": isTouch(),
                    "request-panel-option-two-line": Boolean(request.descriptions[index()]),
                  },
                ]}
                disabled={busy()}
                onClick={() => respond({ value: option })}
              >
                <span class="request-panel-option-title">{option}</span>
                <Show when={request.descriptions[index()]}>
                  {(description) => <span class="request-panel-option-subtitle">{description()}</span>}
                </Show>
              </button>
            )}
          </For>
        </div>,
        cancel(),
      );
    case "ConfirmRequest":
      return frame(
        <p class="request-panel-text">{request.message}</p>,
        <>
          <TonalButton disabled={busy()} onClick={() => respond({ confirmed: false })}>
            {t.requests.no}
          </TonalButton>
          <FilledButton disabled={busy()} onClick={() => respond({ confirmed: true })}>
            {t.requests.yes}
          </FilledButton>
        </>,
      );
    case "InputRequest":
      return frame(
        <TextField
          value={text()}
          hint={request.placeholder}
          onInput={edit}
          onSubmit={(value) => {
            if (!busy()) respond({ value });
          }}
        />,
        <>
          {cancel()}
          {submit()}
        </>,
      );
    case "EditorRequest":
      return frame(
        <EditorField value={text()} onInput={edit} />,
        <>
          {cancel()}
          {submit()}
        </>,
      );
    case "OpenUrlRequest": {
      const web = isWebLink(request.url);
      return frame(
        <div class="request-panel-column">
          <Show when={request.instructions}>
            {(instructions) => <p class="request-panel-text request-panel-instructions">{instructions()}</p>}
          </Show>
          <div class="request-panel-url-row">
            <span class="request-panel-url code-style">{request.url}</span>
            <IconButton
              icon={Symbols.content_copy}
              tooltip={t.common.copy}
              size={isTouch() ? 40 : 32}
              iconSize={18}
              onClick={() => void call("shell.clipboardWrite", { text: request.launchUrl ?? request.url })}
            />
          </div>
          <Show when={!web}>
            <p class="request-panel-small request-panel-error">{t.requests.notWebLink}</p>
          </Show>
          <Show when={forwardNote()}>{(note) => <p class="request-panel-small request-panel-note">{note()}</p>}</Show>
        </div>,
        <>
          <TextButton onClick={() => session.dismissRequest(request.id)}>{t.common.close}</TextButton>
          <FilledButton icon={Symbols.open_in_new} disabled={!web} onClick={() => void openWebLink(request.url)}>
            {t.requests.openInBrowser}
          </FilledButton>
        </>,
      );
    }
    case "CompanionRequest":
      if (request.method === "ask") {
        return (
          <AskForm
            params={request.params}
            draft={draft}
            busy={busy()}
            error={error()}
            navigation={props.navigation}
            onSubmit={(value) => void answer(() => session.companion.respond(request.id, value))}
            onCancel={() => void answer(() => session.companion.cancel(request.id))}
          />
        );
      }
      return frame(
        <div class="request-panel-column">
          <p class="request-panel-text">{t.requests.unsupportedBody({ method: request.method })}</p>
          <pre class="request-panel-json code-style">{JSON.stringify(request.params, null, 2)}</pre>
        </div>,
        <TextButton disabled={busy()} onClick={() => void answer(() => session.companion.cancel(request.id))}>
          {t.common.cancel}
        </TextButton>,
      );
    case "EditorTextRequest":
      throw new Error("set_editor_text fills the composer; it is never shown");
  }
}

function ApprovalBody(props: { readonly session: LiveSession; readonly request: ApprovalRequest }) {
  const shown = sessionViewSelector(
    () => props.session,
    (view) => approvalShown(props.request, view),
    (a, b) => a.intent === b.intent && a.call === b.call && a.details.join("\n") === b.details.join("\n"),
  );
  return (
    <div class="request-panel-column">
      <Show when={shown().intent}>{(intent) => <p class="request-panel-text request-panel-intent">{intent()}</p>}</Show>
      <Show when={shown().call}>{(call) => <pre class="request-panel-call code-style">{call()}</pre>}</Show>
      <For each={shown().details}>{(line) => <p class="request-panel-text request-panel-detail">{line}</p>}</For>
    </div>
  );
}

/** Flutter's multi-line TextField (6 to 16 lines) in the code font: it grows with its text, then scrolls. */
function EditorField(props: { readonly value: string; readonly onInput: (value: string) => void }) {
  let field: HTMLTextAreaElement | undefined;
  const grow = () => {
    if (field === undefined) return;
    field.style.height = "auto";
    field.style.height = `${field.scrollHeight}px`;
  };
  onSettled(grow);
  return (
    <textarea
      ref={(element) => {
        field = element;
      }}
      class="request-panel-editor code-style"
      value={props.value}
      spellcheck="false"
      onInput={(event) => {
        props.onInput(event.currentTarget.value);
        grow();
      }}
    />
  );
}
