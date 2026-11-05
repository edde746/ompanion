// Port of lib/screens/chat/mention_spans.dart.
import type { JSX } from "@solidjs/web";
import { t } from "../../i18n/i18n";
import {
  type MessagePart,
  messageMentionAmong,
  messageMentionFolder,
  messageMentionName,
  messageMentionUrl,
} from "../../sessions/message_mentions";
import { Icon } from "../../widgets/icon";
import * as Symbols from "../../widgets/symbols";
import { tooltip } from "../../widgets/tooltip";
import "./mention_spans.css";

/**
 * `parts` of a user message inline, in the parent's font and colour: text as it is, each file mention a chip with the
 * file's icon and name, its path in a tooltip, each tagged model a chip with its name, its pseudonym in a tooltip.
 * `onOpen` opens a mentioned path on the machine; a `local://` mention, or any mention without `onOpen`, shows its
 * tooltip on tap instead. `folders` are paths omp read as folders, so their mentions show the folder icon even without
 * a trailing separator.
 */
export function mentionSpans(
  parts: readonly MessagePart[],
  options: { onOpen?: (path: string) => void; folders?: readonly string[] } = {},
): JSX.Element {
  const onOpen = options.onOpen;
  return parts.map((part) => {
    switch (part.kind) {
      case "MessageText":
        return part.source;
      case "MessageMention": {
        const url = messageMentionUrl(part);
        const name = messageMentionName(part);
        const icon = messageMentionFolder(part) || messageMentionAmong(part, options.folders ?? [])
          ? Symbols.folder
          : url && name.startsWith("paste-")
            ? Symbols.notes
            : Symbols.draft;
        return chip(icon, name, {
          tooltip: () => part.path,
          onTap: url || onOpen === undefined ? undefined : () => onOpen(part.path),
        });
      }
      case "MessageModel":
        return modelChipSpan(part.name, { agent: part.agent });
    }
  });
}

/**
 * A tagged model as an inline chip: the model icon and `name`. `agent`, the pseudonym omp gave the model, goes in the
 * tooltip.
 */
export function modelChipSpan(name: string, options: { agent?: string } = {}): JSX.Element {
  const agent = options.agent;
  return chip(Symbols.auto_awesome, name, {
    tooltip: agent === undefined ? undefined : () => t.chat.modelAgent({ agent }),
  });
}

function chip(
  icon: string,
  label: string,
  options: { tooltip: (() => string) | undefined; onTap?: () => void },
): JSX.Element {
  const onTap = options.onTap;
  const ref = options.tooltip === undefined ? [] : [tooltip(options.tooltip, { tap: onTap === undefined })];
  const body = (
    <>
      <Icon icon={icon} size={14} class="mention-spans-icon" />
      <span class="mention-spans-label">{label}</span>
    </>
  );
  return onTap === undefined ? (
    <span class="mention-spans-chip" ref={ref}>
      {body}
    </span>
  ) : (
    <button type="button" data-ripple class="mention-spans-chip mention-spans-button" onClick={() => onTap()} ref={ref}>
      {body}
    </button>
  );
}
