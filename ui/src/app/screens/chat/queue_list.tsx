// Port of lib/screens/chat/queue_list.dart; what a row does is in queue_take.ts.
import { For, Show } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import { useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import { splitMentions } from "../../sessions/message_mentions";
import { sessionViewSelector } from "../../sessions/session_view_builder";
import { IconButton } from "../../widgets/button";
import { Icon } from "../../widgets/icon";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import { mentionSpans } from "./mention_spans";
import { verbFailure } from "./mode_verbs";
import { type QueueMode, takeQueued } from "./queue_take";
import "./queue_list.css";

/**
 * Queued steering and follow-up messages, one row each, attached to the top of the composer. A row's edit action takes
 * the message back into the composer, its remove action drops it (companion `queue.take`).
 */
export function QueueList(props: { readonly session: LiveSession }) {
  const sessions = useSessions();
  const queue = sessionViewSelector(
    () => props.session,
    (view) => view.queue,
  );
  const listed = () => queue().steering.length + queue().followUp.length;

  async function take(mode: QueueMode, index: number, edit: boolean) {
    const session = props.session;
    try {
      await takeQueued(session.companion, sessions.draftOf(session), { mode, index, edit });
    } catch (error) {
      showSnackBar(t.queue.takeFailed({ error: verbFailure(error) }));
    }
  }

  const editable = () => props.session.companionHello !== undefined;
  const row = (mode: QueueMode, index: number, text: () => string) => (
    <QueueRow
      icon={mode === "steering" ? Symbols.subdirectory_arrow_right : Symbols.schedule}
      kind={mode === "steering" ? t.queue.steer : t.queue.followUp}
      text={text()}
      onEdit={editable() ? () => void take(mode, index, true) : undefined}
      onRemove={editable() ? () => void take(mode, index, false) : undefined}
    />
  );

  return (
    <Show when={queue().count > 0 || listed() > 0}>
      <div class="queue-list">
        <For each={queue().steering} keyed={false}>
          {(text, index) => row("steering", index, text)}
        </For>
        <For each={queue().followUp} keyed={false}>
          {(text, index) => row("followUp", index, text)}
        </For>
        <Show when={queue().count > listed()}>
          <span class="queue-list-more">{t.queue.more({ n: queue().count - listed() })}</span>
        </Show>
      </div>
    </Show>
  );
}

function QueueRow(props: {
  readonly icon: string;
  readonly kind: string;
  readonly text: string;
  readonly onEdit: (() => void) | undefined;
  readonly onRemove: (() => void) | undefined;
}) {
  return (
    <div class="queue-list-row">
      <span class="queue-list-kind" ref={tooltip(() => props.kind)}>
        <Icon icon={props.icon} size={16} />
      </span>
      <span class="queue-list-text">{mentionSpans(splitMentions(props.text))}</span>
      <IconButton
        icon={Symbols.edit}
        iconSize={16}
        size={32}
        tooltip={t.queue.edit}
        disabled={props.onEdit === undefined}
        onClick={() => props.onEdit?.()}
      />
      <IconButton
        icon={Symbols.close}
        iconSize={16}
        size={32}
        tooltip={t.queue.remove}
        disabled={props.onRemove === undefined}
        onClick={() => props.onRemove?.()}
      />
    </div>
  );
}
