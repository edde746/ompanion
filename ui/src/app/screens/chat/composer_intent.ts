// Port of lib/screens/chat/composer_intent.dart.
import type { StreamingBehavior } from "../../../core/rpc/results";
import type { SlashCommand } from "../../../core/store/session_view";

/** What pressing send does with the composer's content. */
export type ComposerIntent = NothingToSend | SendPrompt | RunBash | RunPython | UnknownCommand;

/** Empty composer, or a bare `!`, `$` or `/`. */
export interface NothingToSend {
  readonly kind: "NothingToSend";
}

/**
 * RPC `prompt` with `text`. `behavior` is undefined for a prompt to an idle session; while a run streams it is `steer`
 * (delivered after the current tool calls) or `followUp` (delivered once the run finishes). Slash commands the session
 * lists travel this way too; the whitespace after their name is a space, since omp ends extension, custom and file
 * command names at the first space only.
 */
export interface SendPrompt {
  readonly kind: "SendPrompt";
  readonly text: string;
  readonly behavior?: StreamingBehavior;
  /** The listed command `text` invokes, when it is one. */
  readonly command?: string;
}

/** `!command` (the TUI's user bash) or `!!command` (`excludeFromContext`): companion `exec.bash`. */
export interface RunBash {
  readonly kind: "RunBash";
  readonly command: string;
  readonly excludeFromContext: boolean;
}

/** `$code` or `$$code` (`excludeFromContext`): companion `exec.python`. */
export interface RunPython {
  readonly kind: "RunPython";
  readonly code: string;
  readonly excludeFromContext: boolean;
}

/**
 * `/name` where the session lists no command `name`. Not sent: omp would hand unknown and TUI-only commands to the
 * model as a paid turn (docs/PLAN.md D14).
 */
export interface UnknownCommand {
  readonly kind: "UnknownCommand";
  readonly name: string;
}

const nothingToSend: NothingToSend = { kind: "NothingToSend" };

/**
 * A command name as typed after `/`: no whitespace and no further `/`, so `/usr/bin is slow` stays a prompt about a
 * path.
 */
const commandName = /^\/([^\s/]+)(?=\s|$)/;

/**
 * Decides what sending `text` does. `running` means a run streams; `followUp` is the follow-up modifier
 * (Alt/Option+Enter) and only matters while `running`. `commands` is the session's live command list.
 */
export function composerIntent(
  text: string,
  options: {
    hasAttachments: boolean;
    running: boolean;
    followUp: boolean;
    commands: readonly SlashCommand[];
  },
): ComposerIntent {
  const trimmed = text.trim();
  if (trimmed.startsWith("!")) {
    const exclude = trimmed.startsWith("!!");
    const command = trimmed.substring(exclude ? 2 : 1).trim();
    return command.length === 0 ? nothingToSend : { kind: "RunBash", command, excludeFromContext: exclude };
  }
  if (trimmed.startsWith("$")) {
    const exclude = trimmed.startsWith("$$");
    const code = trimmed.substring(exclude ? 2 : 1).trim();
    return code.length === 0 ? nothingToSend : { kind: "RunPython", code, excludeFromContext: exclude };
  }
  if (trimmed.length === 0 && !options.hasAttachments) return nothingToSend;
  const behavior: StreamingBehavior | undefined = options.running
    ? options.followUp
      ? "followUp"
      : "steer"
    : undefined;
  if (trimmed === "/") return nothingToSend;
  const match = commandName.exec(trimmed);
  if (match === null) return { kind: "SendPrompt", text: trimmed, behavior };
  const name = match[1]!;
  const command = findCommand(options.commands, name);
  if (command === undefined) return { kind: "UnknownCommand", name };
  // `/name⏎args` would reach omp as the name `name⏎args`, match nothing, and go to the model as a paid turn.
  const args = trimmed.substring(match[0].length);
  const sent = args.length === 0 || args.startsWith(" ") ? trimmed : `/${name} ${args.substring(1)}`;
  return { kind: "SendPrompt", text: sent, behavior, command: command.name };
}

/**
 * The listed command `name` invokes: the one called or aliased so, else for `name:args` the builtin before the colon,
 * since omp splits builtin invocations there too (`/force:bash`).
 */
export function findCommand(commands: readonly SlashCommand[], name: string): SlashCommand | undefined {
  const called = (wanted: string) =>
    commands.find((command) => command.name === wanted || command.aliases.includes(wanted));
  const command = called(name);
  const colon = name.indexOf(":");
  if (command !== undefined || colon <= 0) return command;
  const builtin = called(name.substring(0, colon));
  return builtin?.source === "builtin" ? builtin : undefined;
}
