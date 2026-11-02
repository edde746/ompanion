// Port of lib/screens/chat/attachment_drop.dart.
import type { JSX } from "@solidjs/web";
import { createSignal, onSettled, Show } from "solid-js";
import type { LiveSession } from "../../../core/session/live_session";
import { useSessions } from "../../app_state";
import { t } from "../../i18n/i18n";
import { fileDrag, fileDrops, shellInfo } from "../../platform";
import type { ComposerAttachment } from "../../sessions/composer_attachments";
import { dialogOpen } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import { showSnackBar } from "../../widgets/snackbar";
import * as Symbols from "../../widgets/symbols";
import { attachmentsFrom, attachmentsFromPaths, carriedFiles } from "./attachment_input";
import "./attachment_drop.css";

/**
 * Whether a drag carries files from the OS that the page takes itself, rather than text or a link from a page. A
 * desktop shell with `paths` takes file drags itself (`shell.drag`, `shell.drop`).
 */
function carriesFiles(event: DragEvent): boolean {
  return !shellInfo().paths && (event.dataTransfer?.types.includes("Files") ?? false);
}

/**
 * `children`, the chat pane with its composer, as a target for files and folders dragged in from the OS: while a drag
 * hovers, a flat tone with "Drop to attach" covers the pane, and what is dropped goes into `session`'s draft. A
 * desktop shell's drops (`shell.drop`) name no place in the window: they go to the chat shown.
 */
export function AttachmentDropTarget(props: { readonly session: LiveSession; readonly children: JSX.Element }) {
  const sessions = useSessions();
  const [hovering, setHovering] = createSignal(false);
  // dragenter and dragleave fire for every child the drag crosses; the pane is left when the count returns to zero.
  let depth = 0;
  let pane!: HTMLDivElement;

  // A dialog over the chat would otherwise give its drops to the chat, as would a page pushed over it (which makes the
  // chat inert).
  const takesDrops = () => !dialogOpen() && pane.closest("[inert]") === null;

  async function attach(read: () => Promise<ComposerAttachment[]>) {
    const draft = sessions.draftOf(props.session);
    try {
      const attachments = await read();
      if (attachments.length === 0) {
        showSnackBar(t.composer.dropNothing);
        return;
      }
      draft.addAttachments(attachments);
      draft.requestFocus();
    } catch (error) {
      showSnackBar(t.composer.attachFailed({ error: String(error) }));
    }
  }

  onSettled(() => {
    const subscription = fileDrops.listen((paths) => {
      if (takesDrops()) void attach(() => attachmentsFromPaths(paths));
    });
    return () => subscription.cancel();
  });

  return (
    <div
      class="attachment-drop"
      ref={pane}
      onDragEnter={(event) => {
        if (!carriesFiles(event) || dialogOpen()) return;
        event.preventDefault();
        depth++;
        setHovering(true);
      }}
      onDragOver={(event) => {
        if (!carriesFiles(event) || dialogOpen()) return;
        event.preventDefault();
        if (event.dataTransfer) event.dataTransfer.dropEffect = "copy";
      }}
      onDragLeave={(event) => {
        if (!carriesFiles(event)) return;
        depth = Math.max(0, depth - 1);
        if (depth === 0) setHovering(false);
      }}
      onDrop={(event) => {
        if (!carriesFiles(event) || dialogOpen()) return;
        event.preventDefault();
        depth = 0;
        setHovering(false);
        // A data transfer is emptied once its event returns.
        const carried = event.dataTransfer === null ? [] : carriedFiles(event.dataTransfer);
        void attach(() => attachmentsFrom(carried));
      }}
    >
      {props.children}
      <Show when={shellInfo().paths ? fileDrag() && takesDrops() : hovering()}>
        <div class="attachment-drop-highlight">
          <Icon icon={Symbols.attach_file} size={28} class="attachment-drop-icon" />
          <span class="attachment-drop-label">{t.composer.dropToAttach}</span>
        </div>
      </Show>
    </div>
  );
}
