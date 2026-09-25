import 'package:flutter/material.dart';
import 'package:omp_core/store.dart';

/// The command name typed so far when the composer holds only `/` plus a name being typed, else null. The
/// palette closes at the first whitespace: from there on the user types arguments.
String? paletteQuery(String text) {
  if (!text.startsWith('/')) return null;
  final query = text.substring(1);
  if (query.contains(RegExp(r'[\s/]'))) return null;
  return query;
}

/// [commands] matching [query], best first: name prefix, alias prefix, name substring, then the query's
/// letters in order within the name. Case-insensitive; ties keep the session's order.
List<SlashCommand> filterCommands(List<SlashCommand> commands, String query) {
  final q = query.toLowerCase();
  if (q.isEmpty) return commands;
  final ranked = <(int, int, SlashCommand)>[];
  for (final (index, command) in commands.indexed) {
    final rank = _rank(command, q);
    if (rank != null) ranked.add((rank, index, command));
  }
  ranked.sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
  return [for (final (_, _, command) in ranked) command];
}

int? _rank(SlashCommand command, String q) {
  final name = command.name.toLowerCase();
  if (name.startsWith(q)) return 0;
  if (command.aliases.any((alias) => alias.toLowerCase().startsWith(q))) return 1;
  if (name.contains(q)) return 2;
  var at = 0;
  for (final char in q.split('')) {
    at = name.indexOf(char, at);
    if (at < 0) return null;
    at++;
  }
  return 3;
}

/// The palette list above the composer. [selected] is highlighted; tapping a row picks it.
class SlashPalette extends StatelessWidget {
  const SlashPalette({super.key, required this.commands, required this.selected, required this.onPick});

  final List<SlashCommand> commands;
  final int selected;
  final ValueChanged<SlashCommand> onPick;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      elevation: 3,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 280),
        child: ListView.builder(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 4),
          itemCount: commands.length,
          itemBuilder: (context, index) {
            final command = commands[index];
            final hint = command.hint;
            return ListTile(
              dense: true,
              selected: index == selected,
              selectedTileColor: theme.colorScheme.secondaryContainer,
              title: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(text: '/${command.name}', style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (hint != null)
                      TextSpan(text: '  $hint', style: TextStyle(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
                overflow: TextOverflow.ellipsis,
              ),
              subtitle: command.description == null
                  ? null
                  : Text(command.description!, maxLines: 1, overflow: TextOverflow.ellipsis),
              trailing: Text(command.source, style: theme.textTheme.labelSmall),
              onTap: () => onPick(command),
            );
          },
        ),
      ),
    );
  }
}
