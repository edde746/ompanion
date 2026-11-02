// What lib/screens/chat/chat_header.dart does besides drawing the header: pausing and stopping a run (the composer's Esc
// and the shell's shortcuts do the same), the session menu's commands and its stop. The snack bar comes in as `snack`,
// as the Dart takes the context for its messenger: bun tests cannot import the widgets.
import { isJsonObject } from "../../../core/rpc/json_fields";
import type { LiveSession } from "../../../core/session/live_session";
import type { SessionView } from "../../../core/store/session_view";
import { t } from "../../i18n/i18n";
import type { ComposerDraft } from "../../sessions/composer_draft";
import type { SessionsProvider } from "../../sessions/sessions_provider";
import { findCommand } from "./composer_intent";
import { offersVerb, verbFailure } from "./mode_verbs";
import { decodeRestored, type RestoredMessage, restoreIntoDraft } from "./queue_restore";

/** Shows `text` in a snack bar. */
export type Snack = (text: string) => void;

/** What a failure says, as Dart's `'$error'` shows an exception. */
export function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Engages or releases the companion's pause gate of `session` (the TUI's `/pause`). */
export async function togglePauseWith(session: LiveSession, snack: Snack): Promise<void> {
  // Without the companion a `/ompx` call would reach the model as a prompt.
  if (session.companionHello === undefined) {
    snack(t.chat.noCompanion);
    return;
  }
  try {
    await session.companion.call("pause.set", { paused: !session.view.run.paused });
  } catch (error) {
    snack(t.chat.pauseFailed({ error: errorText(error) }));
  }
}

/**
 * Aborts `session`'s run as Esc does in the TUI: the queued messages go back into `draft` ahead of its text (companion
 * `queue.clear` with `interrupt`, which also drops omp's own queued steers so the run cannot resume by itself), a
 * running loop is suspended, omp aborts, and a pause gate is released, since nothing is left for it to hold. omp itself
 * pauses an active goal on the abort.
 */
export async function abortRunWith(session: LiveSession, draft: ComposerDraft, snack: Snack): Promise<void> {
  const companion = session.companionHello !== undefined;
  if (companion) {
    try {
      const cleared = await session.companion.call("queue.clear", { interrupt: true });
      if (isJsonObject(cleared) && Array.isArray(cleared.steering) && Array.isArray(cleared.followUp)) {
        const messages = [...cleared.steering, ...cleared.followUp]
          .map(decodeRestored)
          .filter((message): message is RestoredMessage => message !== undefined);
        restoreIntoDraft(draft, messages);
      }
    } catch (error) {
      // The run still stops; only the queue stays where it was.
      snack(t.queue.takeFailed({ error: errorText(error) }));
    }
  }
  // Before the abort: the end of the aborted turn would otherwise start the loop's next iteration.
  const loop = session.view.loop;
  if (loop !== undefined && !loop.paused && offersVerb(session, "loop.suspend")) {
    try {
      await session.companion.call("loop.suspend");
    } catch (error) {
      snack(t.loop.failed({ error: verbFailure(error) }));
    }
  }
  try {
    await session.rpc.abort();
    if (companion && session.view.run.paused) await session.companion.call("pause.set", { paused: false });
  } catch (error) {
    snack(t.chat.abortFailed({ error: errorText(error) }));
  }
}

/** A command the session menu starts in the composer. */
export type MenuCommand = "goal" | "guided-goal" | "loop";

/**
 * The session's commands the menu starts in the composer: `/goal`, `/guided-goal` and `/loop`, those the session
 * lists, and `/loop` only while no loop is on, since `/loop` then turns it off whatever follows.
 */
export function sessionMenuCommands(view: SessionView): MenuCommand[] {
  const commands: MenuCommand[] = ["goal", "guided-goal", "loop"];
  return commands.filter(
    (name) => findCommand(view.commands, name) !== undefined && (name !== "loop" || view.loop === undefined),
  );
}

/** Stops `session`'s omp process; a failed stop leaves the session open and says why. */
export async function stopSession(
  sessions: Pick<SessionsProvider, "stop">,
  session: LiveSession,
  snack: Snack,
): Promise<void> {
  try {
    await sessions.stop(session);
  } catch (error) {
    snack(t.chat.stopSessionFailed({ error: errorText(error) }));
  }
}
