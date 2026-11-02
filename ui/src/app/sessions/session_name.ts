// lib/sessions/session_name.dart: the name a session goes by in the sidebar and the chat header.
import type { SessionSummary } from "../../core/host/session_listing";
import { textOf } from "../../core/store/content";
import type { SessionView } from "../../core/store/session_view";
import { t } from "../i18n/i18n";
import { messageMentionName, splitMentions } from "./message_mentions";

/**
 * {@link sessionName} of a session open on this device: its live title, else the first message of its file in the
 * machine's listing (`summary`), else the first one in its transcript.
 */
export function liveSessionName(view: SessionView, summary: SessionSummary | undefined): string {
  return sessionName({ title: view.config.sessionName, firstMessage: summary?.firstMessage ?? firstUserMessage(view) });
}

/**
 * The name a session goes by in the sidebar and the chat header: omp's title, else its first user message on one line
 * without its file mentions, a tagged model by its name (the first file's name when it has nothing else), else "New
 * session".
 */
export function sessionName(options: { title?: string; firstMessage?: string }): string {
  const title = options.title?.trim();
  if (title) return title;
  const cut = options.firstMessage?.replace(cutQuotedMention, (_, before: string) => before).replace(cutModelTag, "");
  const parts = splitMentions(cut ?? "");
  const text = parts
    .map((part) => (part.kind === "MessageText" ? part.source : part.kind === "MessageModel" ? part.name : " "))
    .join("")
    .replace(/\s+/g, " ")
    .trim();
  if (text !== "") return text;
  const first = parts.find((part) => part.kind === "MessageMention");
  return first?.kind === "MessageMention" ? messageMentionName(first) : t.sessions.untitled;
}

/** A quoted mention the machine's listing cut off at `firstMessageLength`: what is left of its path is no name. */
const cutQuotedMention = /(^|[\s(\[{<"'`])@(?:"[^"]*|'[^']*)$/;

/** A model tag the listing cut off: no name to show. */
const cutModelTag = /<model [^>]*$/;

/**
 * Text of the first message the user typed in `view`'s transcript; before the machine's listing has the session file,
 * this is where a new session's name comes from.
 */
export function firstUserMessage(view: SessionView): string | undefined {
  for (const item of view.transcript) {
    if (item.kind === "UserItem" && !item.synthetic && item.attribution !== "agent") {
      const text = textOf(item.content);
      if (text.trim() !== "") return text;
    }
  }
  return undefined;
}
