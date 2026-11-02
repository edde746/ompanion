// Port of lib/screens/chat/chat_screen.dart; resetToEntry and branchFrom are in chat_actions.ts.
import type { JSX } from "@solidjs/web";
import { createMemo, Show } from "solid-js";
import { call } from "../../../bridge";
import { ExternalSession } from "../../../core/session/external_session";
import type { LiveSession } from "../../../core/session/live_session";
import { useDock, useImages, useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import { linkState, sessionView } from "../../sessions/session_view_builder";
import { FilledButton, TextButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { showSnackBar } from "../../widgets/snackbar";
import { windowDragArea } from "../../window_chrome";
import { AttachmentDropTarget } from "./attachment_drop";
import { branchFrom, type ChatPrompts, resetToEntry } from "./chat_actions";
import { ChatHeader } from "./chat_header";
import { Composer } from "./composer";
import { ExecPanel } from "./exec_panel";
import { LinkBanner } from "./link_banner";
import { RequestPanel } from "./request_panel";
import { CommandOutputs, ExtensionWidgets, NoticeHost, StatusStrip } from "./status_strip";
import { type TranscriptActions, TranscriptScope, TranscriptStorage } from "./transcript/transcript_actions";
import { TranscriptView } from "./transcript/transcript_view";
import "./chat_screen.css";

export interface ChatScreenProps {
  /** Shell buttons at the ends of the header (sidebar and panel toggles). */
  readonly leading: JSX.Element;
  readonly trailing: JSX.Element;
  /** Phone layout. */
  readonly compact: boolean;
  /** The session to show: the phone layout's page keeps its own while another page slides over it. */
  readonly session?: LiveSession;
}

/** The dialogs and snack bars chat_actions.ts asks for. */
const prompts: ChatPrompts = {
  async confirm(options) {
    const agreed = await showDialog<boolean>((close) => (
      <Dialog
        title={options.title}
        actions={
          <>
            <TextButton onClick={() => close(false)}>{t.common.cancel}</TextButton>
            <FilledButton onClick={() => close(true)}>{options.action}</FilledButton>
          </>
        }
      >
        {options.body}
      </Dialog>
    ));
    return agreed === true;
  },
  // An action makes Flutter's snack bar persist; this one sits over the composer's send button, so it leaves.
  snack: (text, action) => showSnackBar(text, action === undefined ? {} : { action }),
};

/**
 * The chat of the session the center pane shows (`SessionsProvider.active`): header, transcript, the panels above the
 * composer, the open requests inline, and the composer. Nothing in the chat is modal; toasts show as snack bars.
 */
export function ChatScreen(props: ChatScreenProps) {
  const sessions = useSessions();
  return (
    <Show
      when={props.session ?? sessions.active()}
      keyed
      fallback={
        <div class="chat-screen">
          <div class="chat-screen-header" ref={windowDragArea}>
            {props.leading}
            <span class="chat-screen-place" />
            {props.trailing}
          </div>
        </div>
      }
    >
      {(session) => <SessionChat session={session} leading={props.leading} trailing={props.trailing} compact={props.compact} />}
    </Show>
  );
}

function SessionChat(props: ChatScreenProps & { readonly session: LiveSession }) {
  const sessions = useSessions();
  const dock = useDock();
  const images = useImages();
  const session = () => props.session;
  const view = sessionView(session);
  const link = linkState(session);
  const storage = new Map<string, unknown>();
  const sessionImages = createMemo(() => images.forSession(sessions, props.session));

  async function copy(text: string) {
    await call("shell.clipboardWrite", { text });
    showSnackBar(t.common.copied, { durationMs: 1000 });
  }

  // A session another omp process writes has no RPC to branch or reset with.
  const actions = createMemo((): TranscriptActions => {
    const current = props.session;
    const writable = !(current instanceof ExternalSession);
    return {
      onBranchFrom: writable ? (entryId) => void branchFrom(current, sessions, entryId, prompts) : undefined,
      onResetTo: writable
        ? (entryId, kind) => void resetToEntry(current, sessions, { entryId, kind, openTree: () => dock.show("tree") }, prompts)
        : undefined,
      // Read on every new view, so the reset buttons follow a run that starts or ends.
      canReset: !view().run.running,
      onCopy: (text) => void copy(text),
      onOpenFile: (path, options) => dock.openFile(path, options),
      onOpenSubagent: (id) => dock.openSubagent(id),
      // A large session opens with its latest part; the transcript asks for earlier pages as the reader scrolls up.
      onLoadEarlier: current.loadEarlier,
      images: sessionImages(),
    };
  });

  return (
    <AttachmentDropTarget session={props.session}>
      <NoticeHost session={props.session} />
      <div class={["chat-screen", { "chat-screen-compact": props.compact }]}>
        <ChatHeader session={props.session} leading={props.leading} trailing={props.trailing} compact={props.compact} />
        <LinkBanner session={props.session} />
        {/* The strips and panels around the transcript, and the composer, share its column. */}
        <div class="chat-screen-column">
          <StatusStrip session={props.session} />
        </div>
        <div class="chat-screen-transcript">
          <TranscriptView
            view={view()}
            actions={actions()}
            turns={sessions.turnsOf(props.session)}
            closed={link().kind === "LinkClosed"}
          />
        </div>
        {/* The home indicator's inset is the room under the composer; without one, 8 px. */}
        <div class="chat-screen-bottom">
          <div class="chat-screen-column">
            <CommandOutputs session={props.session} />
            <ExecPanel session={props.session} />
            <ExtensionWidgets session={props.session} placement="aboveEditor" />
            {/* The ask form renders its questions as transcript markdown: links to files and code copies act here. */}
            <TranscriptScope value={actions}>
              <TranscriptStorage value={storage}>
                <RequestPanel session={props.session} />
              </TranscriptStorage>
            </TranscriptScope>
            <Composer session={props.session} />
            <ExtensionWidgets session={props.session} placement="belowEditor" />
          </div>
        </div>
      </div>
    </AttachmentDropTarget>
  );
}
