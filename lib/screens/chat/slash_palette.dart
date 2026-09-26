import 'package:flutter/material.dart';
import 'package:omp_core/store.dart';

import '../../app/theme.dart';
import 'transcript/code_style.dart';

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

/// The palette list above the composer: one dense row per command, up to [_visibleRows] at once with a visible
/// scrollbar when there are more. [selected] is highlighted and kept in view; tapping a row picks it.
class SlashPalette extends StatefulWidget {
  const SlashPalette({super.key, required this.commands, required this.selected, required this.onPick});

  final List<SlashCommand> commands;
  final int selected;
  final ValueChanged<SlashCommand> onPick;

  @override
  State<SlashPalette> createState() => _SlashPaletteState();
}

const _rowHeight = 36.0;
const _visibleRows = 10;

class _SlashPaletteState extends State<SlashPalette> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(SlashPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new filter result starts over at its first row.
    if (oldWidget.selected != widget.selected || !identical(oldWidget.commands, widget.commands)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the least distance that shows the selected row.
  void _reveal() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final top = widget.selected * _rowHeight;
    final bottom = top + _rowHeight;
    final target = top < position.pixels
        ? top
        : bottom > position.pixels + position.viewportDimension
        ? bottom - position.viewportDimension
        : null;
    if (target != null) _scroll.jumpTo(target.clamp(0, position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final commands = widget.commands;
    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: const BorderRadius.all(Radius.circular(AppSizes.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: _rowHeight * _visibleRows + 8),
        child: Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: ListView.builder(
            controller: _scroll,
            shrinkWrap: true,
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemExtent: _rowHeight,
            itemCount: commands.length,
            itemBuilder: (context, index) {
              final command = commands[index];
              final hint = command.hint;
              final description = command.description;
              return InkWell(
                onTap: () => widget.onPick(command),
                child: Container(
                  color: index == widget.selected ? theme.colorScheme.surfaceContainerHighest : null,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      Text(
                        '/${command.name}',
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: AppSizes.gap),
                      // The argument hint first, then the description, both secondary.
                      Expanded(
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (hint != null)
                                TextSpan(
                                  text: hint,
                                  style: codeTextStyle(theme).copyWith(fontSize: 12, color: muted),
                                ),
                              if (hint != null && description != null) const TextSpan(text: '   '),
                              ?(description == null ? null : TextSpan(text: description)),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodySmall?.copyWith(color: muted),
                        ),
                      ),
                      const SizedBox(width: AppSizes.gap),
                      Text(command.source, style: theme.textTheme.labelSmall?.copyWith(color: muted)),
                      // Room for the scrollbar.
                      const SizedBox(width: 8),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
