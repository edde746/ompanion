// Port of lib/screens/chat/attachment_chips.dart.
import { For, Match, Show, Switch } from "solid-js";
import { base64Decode } from "../../../core/util/base64";
import { t } from "../../i18n/i18n";
import {
  type ComposerAttachment,
  type FileAttachment,
  type ImageAttachment,
  type TextAttachment,
  textAttachmentLineCount,
} from "../../sessions/composer_attachments";
import { formatBytes } from "../../utils/byte_size";
import { TextButton, TonalButton } from "../../widgets/button";
import { Dialog, showDialog } from "../../widgets/dialog";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import { showZoomedImage } from "./transcript/images_view";
import "./attachment_chips.css";

export interface AttachmentChipsProps {
  readonly attachments: readonly ComposerAttachment[];
  readonly onRemove: (attachment: ComposerAttachment) => void;
  /** "Paste inline" in a pasted text's preview. */
  readonly onInline: (attachment: TextAttachment) => void;
}

/**
 * The draft's attachments above the composer's text, in the order they came: image thumbnails that open the zoom
 * viewer, files and folders by name and size, pasted texts by line count, which open a preview. Every chip has a
 * remove button, and Tab reaches every chip that acts and every remove button.
 */
export function AttachmentChips(props: AttachmentChipsProps) {
  return (
    <div class="attachment-chips">
      <For each={props.attachments}>
        {(attachment) => (
          <Switch>
            <Match when={attachment.kind === "ImageAttachment" && attachment}>
              {(image) => <ImageChip attachment={image()} onRemove={() => props.onRemove(attachment)} />}
            </Match>
            <Match when={attachment.kind === "FileAttachment" && attachment}>
              {(file) => <FileChip attachment={file()} onRemove={() => props.onRemove(attachment)} />}
            </Match>
            <Match when={attachment.kind === "TextAttachment" && attachment}>
              {(text) => (
                <TextChip
                  attachment={text()}
                  onRemove={() => props.onRemove(attachment)}
                  onInline={() => props.onInline(text())}
                />
              )}
            </Match>
          </Switch>
        )}
      </For>
    </div>
  );
}

function ImageChip(props: { readonly attachment: ImageAttachment; readonly onRemove: () => void }) {
  const label = () => props.attachment.name ?? t.composer.pastedImage;
  return (
    <span class="attachment-chips-image">
      <button
        type="button"
        data-ripple
        class="attachment-chips-thumbnail"
        ref={tooltip(label)}
        onClick={() => void showZoomedImage(base64Decode(props.attachment.image.data))}
      >
        <img
          src={`data:${props.attachment.image.mimeType};base64,${props.attachment.image.data}`}
          alt={label()}
          width="64"
          height="64"
        />
      </button>
      <RemoveButton onRemove={props.onRemove} onImage />
    </span>
  );
}

function FileChip(props: { readonly attachment: FileAttachment; readonly onRemove: () => void }) {
  // A folder has no size of its own.
  const folder = () => props.attachment.folder === true;
  return (
    <Chip
      tooltip={props.attachment.name}
      icon={folder() ? Symbols.folder : Symbols.draft}
      label={props.attachment.name}
      detail={folder() ? undefined : formatBytes(props.attachment.size)}
      onRemove={props.onRemove}
    />
  );
}

function TextChip(props: {
  readonly attachment: TextAttachment;
  readonly onRemove: () => void;
  readonly onInline: () => void;
}) {
  async function preview() {
    const inline = await showDialog<boolean>((close) => <PastedTextPreview attachment={props.attachment} close={close} />);
    if (inline) props.onInline();
  }
  return (
    <Chip
      icon={Symbols.notes}
      label={t.composer.pastedText({ n: textAttachmentLineCount(props.attachment) })}
      onTap={() => void preview()}
      onRemove={props.onRemove}
    />
  );
}

/** A file or text chip: one control tall, the chip tone, icon, label, an optional muted detail and the remove button. */
function Chip(props: {
  readonly icon: string;
  readonly label: string;
  readonly detail?: string;
  readonly tooltip?: string;
  readonly onTap?: () => void;
  readonly onRemove: () => void;
}) {
  const body = (
    <>
      <Icon icon={props.icon} size={16} class="attachment-chips-icon" />
      <span class="attachment-chips-label">{props.label}</span>
      <Show when={props.detail}>{(detail) => <span class="attachment-chips-detail">{detail()}</span>}</Show>
    </>
  );
  return (
    <span class="attachment-chips-chip" ref={props.tooltip === undefined ? undefined : tooltip(() => props.tooltip ?? "")}>
      <Show when={props.onTap} fallback={<span class="attachment-chips-body">{body}</span>}>
        {(onTap) => (
          <button type="button" data-ripple class="attachment-chips-body attachment-chips-tap" onClick={() => onTap()()}>
            {body}
          </button>
        )}
      </Show>
      <RemoveButton onRemove={props.onRemove} />
    </span>
  );
}

function RemoveButton(props: { readonly onRemove: () => void; readonly onImage?: boolean }) {
  return (
    <button
      type="button"
      data-ripple
      class={["attachment-chips-remove", { "attachment-chips-remove-on-image": props.onImage }]}
      ref={tooltip(() => t.composer.remove)}
      onClick={() => props.onRemove()}
    >
      <Icon icon={Symbols.close} size={14} />
    </button>
  );
}

/** Very long pastes show their start: laying out megabytes of text at once would stall the window. */
const shownCharacters = 50000;

/** A pasted text, read-only, with "Paste inline" to move it into the text field. */
function PastedTextPreview(props: { readonly attachment: TextAttachment; readonly close: (inline?: boolean) => void }) {
  const text = () => props.attachment.text;
  const truncated = () => text().length > shownCharacters;
  return (
    <Dialog
      title={t.composer.pastedText({ n: textAttachmentLineCount(props.attachment) })}
      class="attachment-chips-preview"
      actions={
        <>
          <TextButton onClick={() => props.close(false)}>{t.common.close}</TextButton>
          <TonalButton onClick={() => props.close(true)}>{t.composer.pasteInline}</TonalButton>
        </>
      }
    >
      <pre class="attachment-chips-preview-text">{truncated() ? text().substring(0, shownCharacters) : text()}</pre>
      <Show when={truncated()}>
        <p class="attachment-chips-preview-note">
          {t.composer.previewTruncated({ shown: shownCharacters, total: text().length })}
        </p>
      </Show>
    </Dialog>
  );
}
