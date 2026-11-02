// Port of lib/sessions/message_mentions.dart.

/**
 * A piece of a user message: typed text, a reference to a file or a tagged model. The parts' sources joined are the
 * message.
 */
export type MessagePart = MessageText | MessageMention | MessageModel;

export interface MessageText {
  readonly kind: "MessageText";
  /** The characters of the message this part covers. */
  readonly source: string;
}

/** An `@` mention omp auto-reads, or a `local://` reference such as the `local://paste-1.md` a large paste becomes. */
export interface MessageMention {
  readonly kind: "MessageMention";
  readonly source: string;
  /** The path as omp resolves it: host-native, `~/…`, relative to the session's directory, or a `local://` URL. */
  readonly path: string;
}

/**
 * A model the user tagged with `^provider/id`, as omp writes it into the message: `<model agent="m1" name="…"/>`.
 * `agent` is the pseudonym `task` and eval's `agent()` take to spawn a subagent on that model.
 */
export interface MessageModel {
  readonly kind: "MessageModel";
  readonly source: string;
  readonly agent: string;
  /** The model's display name when it was tagged. */
  readonly name: string;
}

const trailingSeparators = /[/\\]+$/;

/** The last segment of the mention's path: a file's or folder's name. */
export function messageMentionName(mention: MessageMention): string {
  const trimmed = mention.path.replace(trailingSeparators, "");
  if (trimmed === "") return mention.path;
  return trimmed.substring(Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\")) + 1);
}

/** A `local://` or other internal URL, which is not a path on the machine. */
export function messageMentionUrl(mention: MessageMention): boolean {
  return /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(mention.path);
}

/** Mentions a folder: the path ends in a separator. */
export function messageMentionFolder(mention: MessageMention): boolean {
  return trailingSeparators.test(mention.path);
}

/** omp's `MODEL_MENTION_TAG_RE` (packages/tui/src/prompt/model-mention-syntax.ts). Global: for matchAll and replace. */
export const modelTag = /<model agent="(m\d+)" name="([^"]*)"\/>/g;

// omp's rules (packages/coding-agent/src/utils/file-mentions.ts, `extractFileMentions`): FILE_MENTION_REGEX, a match
// counts only at the start or after MENTION_BOUNDARY_REGEX, and an unquoted path loses leading and trailing
// punctuation. The `local://` alternative is ours; it takes no `@`, so it never swallows a mention omp would find.
const mention = /@(?:"([^"]+)"|'([^']+)'|([^\s@]+))|local:\/\/[^\s@]+/g;
const boundary = /[\s(\[{<"'`]/;
const leadingPunctuation = /^[`"'(\[{<]+/;
const trailingPunctuation = /[)\]}>.,;:!?"'`]+$/;

/** `message` split into text, the mentions omp reads in it and the models it tagged, in order. */
export function splitMentions(message: string): MessagePart[] {
  const parts: MessagePart[] = [];
  let done = 0;
  for (const tag of message.matchAll(modelTag)) {
    splitFiles(message, done, tag.index, parts);
    parts.push({ kind: "MessageModel", source: tag[0], agent: tag[1]!, name: tag[2]! });
    done = tag.index + tag[0].length;
  }
  splitFiles(message, done, message.length, parts);
  return parts;
}

/** Adds the text and file mentions of `message` from `start` to `end` to `parts`. */
function splitFiles(message: string, start: number, end: number, parts: MessagePart[]): void {
  const text = message.substring(start, end);
  let done = 0;
  for (const match of text.matchAll(mention)) {
    const at = start + match.index;
    if (at > 0 && !boundary.test(message[at - 1]!)) continue;
    const quoted = match[1] ?? match[2];
    let path: string;
    let matchEnd = match.index + match[0].length;
    if (quoted !== undefined) {
      path = quoted.trim();
    } else {
      const unled = (match[3] ?? match[0]).replace(leadingPunctuation, "");
      const cleaned = unled.replace(trailingPunctuation, "");
      matchEnd -= unled.length - cleaned.length;
      path = cleaned;
    }
    if (path === "" || path === "local://") continue;
    if (match.index > done) parts.push({ kind: "MessageText", source: text.substring(done, match.index) });
    parts.push({ kind: "MessageMention", source: text.substring(match.index, matchEnd), path });
    done = matchEnd;
  }
  if (done < text.length) parts.push({ kind: "MessageText", source: text.substring(done) });
}
