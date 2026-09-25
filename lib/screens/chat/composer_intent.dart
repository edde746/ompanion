import 'package:omp_core/rpc.dart';
import 'package:omp_core/store.dart';

/// What pressing send does with the composer's content.
sealed class ComposerIntent {
  const ComposerIntent();
}

/// Empty composer, or a bare `!`, `$` or `/`.
final class NothingToSend extends ComposerIntent {
  const NothingToSend();
}

/// RPC `prompt` with [text]. [behavior] is null for a prompt to an idle session; while a run streams it is
/// [StreamingBehavior.steer] (delivered after the current tool calls) or [StreamingBehavior.followUp]
/// (delivered once the run finishes). Slash commands the session lists travel this way too; the whitespace after
/// their name is a space, since omp ends extension, custom and file command names at the first space only.
final class SendPrompt extends ComposerIntent {
  const SendPrompt(this.text, {this.behavior, this.command});

  final String text;
  final StreamingBehavior? behavior;

  /// The listed command [text] invokes, when it is one.
  final String? command;
}

/// `!command` (the TUI's user bash) or `!!command` ([excludeFromContext]): companion `exec.bash`.
final class RunBash extends ComposerIntent {
  const RunBash(this.command, {required this.excludeFromContext});

  final String command;
  final bool excludeFromContext;
}

/// `$code` or `$$code` ([excludeFromContext]): companion `exec.python`.
final class RunPython extends ComposerIntent {
  const RunPython(this.code, {required this.excludeFromContext});

  final String code;
  final bool excludeFromContext;
}

/// `/name` where the session lists no command [name]. Not sent: omp would hand unknown and TUI-only
/// commands to the model as a paid turn (docs/PLAN.md D14).
final class UnknownCommand extends ComposerIntent {
  const UnknownCommand(this.name);

  final String name;
}

/// A command name as typed after `/`: no whitespace and no further `/`, so `/usr/bin is slow` stays a
/// prompt about a path.
final _commandName = RegExp(r'^/([^\s/]+)(?=\s|$)');

/// Decides what sending [text] does. [running] means a run streams; [followUp] is the follow-up modifier
/// (Alt/Option+Enter) and only matters while [running]. [commands] is the session's live command list.
ComposerIntent composerIntent(
  String text, {
  required bool hasImages,
  required bool running,
  required bool followUp,
  required List<SlashCommand> commands,
}) {
  final trimmed = text.trim();
  if (trimmed.startsWith('!')) {
    final exclude = trimmed.startsWith('!!');
    final command = trimmed.substring(exclude ? 2 : 1).trim();
    return command.isEmpty ? const NothingToSend() : RunBash(command, excludeFromContext: exclude);
  }
  if (trimmed.startsWith(r'$')) {
    final exclude = trimmed.startsWith(r'$$');
    final code = trimmed.substring(exclude ? 2 : 1).trim();
    return code.isEmpty ? const NothingToSend() : RunPython(code, excludeFromContext: exclude);
  }
  if (trimmed.isEmpty && !hasImages) return const NothingToSend();
  final behavior = running ? (followUp ? StreamingBehavior.followUp : StreamingBehavior.steer) : null;
  if (trimmed == '/') return const NothingToSend();
  final match = _commandName.firstMatch(trimmed);
  if (match == null) return SendPrompt(trimmed, behavior: behavior);
  final name = match.group(1)!;
  final command = findCommand(commands, name);
  if (command == null) return UnknownCommand(name);
  // `/name⏎args` would reach omp as the name `name⏎args`, match nothing, and go to the model as a paid turn.
  final args = trimmed.substring(match.end);
  final sent = args.isEmpty || args.startsWith(' ') ? trimmed : '/$name ${args.substring(1)}';
  return SendPrompt(sent, behavior: behavior, command: command.name);
}

/// The listed command [name] invokes: the one called or aliased so, else for `name:args` the builtin before the
/// colon, since omp splits builtin invocations there too (`/force:bash`).
SlashCommand? findCommand(List<SlashCommand> commands, String name) {
  SlashCommand? called(String name) =>
      commands.where((command) => command.name == name || command.aliases.contains(name)).firstOrNull;
  final command = called(name);
  final colon = name.indexOf(':');
  if (command != null || colon <= 0) return command;
  final builtin = called(name.substring(0, colon));
  return builtin?.source == 'builtin' ? builtin : null;
}
