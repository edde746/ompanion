// What the composer's lists above it show: the slash palette's query and ranking (lib/screens/chat/slash_palette.dart),
// the `^` model mention (model_mention_palette.dart) and the model filter every model list shares (model_picker.dart).
import { asJsonObject, strings } from "../../../core/rpc/json_fields";
import type { RpcModel } from "../../../core/rpc/results";
import type { LiveSession } from "../../../core/session/live_session";
import type { SlashCommand } from "../../../core/store/session_view";
import type { TextValue } from "../../sessions/composer_draft";
import { offersVerb } from "./mode_verbs";

/**
 * The command name typed so far when the composer holds only `/` plus a name being typed, else undefined. The palette
 * closes at the first whitespace: from there on the user types arguments.
 */
export function paletteQuery(text: string): string | undefined {
  if (!text.startsWith("/")) return undefined;
  const query = text.substring(1);
  return /[\s/]/.test(query) ? undefined : query;
}

/**
 * `commands` matching `query`, best first: name prefix, alias prefix, name substring, then the query's letters in
 * order within the name. Case-insensitive; ties keep the session's order.
 */
export function filterCommands(commands: readonly SlashCommand[], query: string): readonly SlashCommand[] {
  const q = query.toLowerCase();
  if (q.length === 0) return commands;
  const ranked: { rank: number; index: number; command: SlashCommand }[] = [];
  commands.forEach((command, index) => {
    const rank = commandRank(command, q);
    if (rank !== undefined) ranked.push({ rank, index, command });
  });
  ranked.sort((a, b) => a.rank - b.rank || a.index - b.index);
  return ranked.map((entry) => entry.command);
}

function commandRank(command: SlashCommand, q: string): number | undefined {
  const name = command.name.toLowerCase();
  if (name.startsWith(q)) return 0;
  if (command.aliases.some((alias) => alias.toLowerCase().startsWith(q))) return 1;
  if (name.includes(q)) return 2;
  let at = 0;
  for (const character of q) {
    at = name.indexOf(character, at);
    if (at < 0) return undefined;
    at++;
  }
  return 3;
}

/**
 * Whether `^` tags a model in `text`: not in a `!` or `$` draft, whose body runs as it is, as omp's
 * `allowsModelMentions` (packages/tui/src/prompt/skill-tokens.ts) keeps mentions literal there.
 */
export function allowsModelMentions(text: string): boolean {
  const trimmed = text.trimStart();
  return !trimmed.startsWith("!") && !trimmed.startsWith("$");
}

/** A `^` token at the cursor: where it starts and what follows the `^`. */
export interface MentionQuery {
  readonly start: number;
  readonly query: string;
}

const mentionToken = /(?:^|\s)(\^\S*)$/;

/**
 * The `^` token being typed at the cursor of `value`, else undefined. A token starts the text or follows whitespace
 * and runs to the cursor without whitespace, as omp's `MODEL_MENTION_CONTEXT_RE`
 * (packages/tui/src/prompt/model-mention-autocomplete.ts) reads it.
 */
export function mentionQuery(value: TextValue): MentionQuery | undefined {
  const selection = value.selection;
  if (selection === undefined || selection.start !== selection.end || !allowsModelMentions(value.text)) {
    return undefined;
  }
  const before = value.text.substring(0, selection.start);
  const token = mentionToken.exec(before)?.[1];
  if (token === undefined) return undefined;
  return { start: before.length - token.length, query: token.substring(1) };
}

/** The selector omp matches a mention against: `formatModelString`, `provider/id`. */
export function modelSelector(model: RpcModel): string {
  return `${model.provider}/${model.id}`;
}

/**
 * The name omp shows for a tagged model: `modelMentionDisplayName`, the catalog name without quotes, or the id when
 * the name is empty.
 */
export function modelDisplayName(model: RpcModel): string {
  const name = model.name.trim();
  return (name.length === 0 ? model.id : name).replaceAll('"', "");
}

/**
 * `models` holding every whitespace-separated word of `query` in `provider/id` or their name (case-insensitive): first
 * the ones in `recent` (omp's most recently used, newest first, {@link recentModels}) in its order, then the rest by
 * provider, the providers of recent models first, then name. So the copy of a model from the provider in use leads
 * the same model from other providers, as in omp's picker. The model list, the `^` list and the config pickers.
 */
export function filterModels(models: readonly RpcModel[], query: string, recent: readonly string[]): RpcModel[] {
  const words = query
    .toLowerCase()
    .split(/\s+/)
    .filter((word) => word.length > 0);
  const matching = models.filter((model) => {
    const haystack = `${model.provider}/${model.id} ${model.name}`.toLowerCase();
    return words.every((word) => haystack.includes(word));
  });
  const used = new Map(recent.map((selector, index) => [selector, index]));
  const providers = new Map<string, number>();
  for (const selector of recent) {
    const provider = selector.slice(0, Math.max(0, selector.indexOf("/")));
    if (provider !== "" && !providers.has(provider)) providers.set(provider, providers.size);
  }
  const last = Number.MAX_SAFE_INTEGER;
  const usedRank = (model: RpcModel) => used.get(modelSelector(model)) ?? last;
  const providerRank = (model: RpcModel) => providers.get(model.provider) ?? last;
  return matching.sort(
    (a, b) =>
      usedRank(a) - usedRank(b) ||
      providerRank(a) - providerRank(b) ||
      compare(a.provider, b.provider) ||
      compare(a.name, b.name),
  );
}

/**
 * omp's most recently used models on `session`'s machine, newest first (`provider/id`): the companion's
 * `models.recent`, which every model switch there updates, the TUI's too. None without a companion that has it.
 */
export async function recentModels(session: Pick<LiveSession, "companion" | "companionHello">): Promise<string[]> {
  if (!offersVerb(session, "models.recent")) return [];
  return strings(asJsonObject(await session.companion.call("models.recent"), "models.recent"), "models");
}

/** Dart's String.compareTo: by UTF-16 code units, not by locale. */
function compare(a: string, b: string): number {
  return a < b ? -1 : a > b ? 1 : 0;
}
