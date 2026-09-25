import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/session.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xterm3/xterm.dart';

import '../../../app/dev_overrides.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/machine.dart';
import '../../../sessions/sessions_provider.dart';
import '../../../terminal/shell_launch.dart';
import '../../../terminal/terminal_deck.dart';
import '../../../terminal/terminal_session.dart';
import '../../chat/transcript/code_style.dart';
import '../dock_controller.dart';
import '../dock_empty_state.dart';
import '../machine_access.dart';

/// Terminals on the machine, as tabs: SSH PTY channels on remote machines, a local PTY on this computer. New
/// terminals start in the session's directory.
class TerminalTab extends StatefulWidget {
  const TerminalTab({super.key, required this.machine, required this.session});

  final Machine machine;
  final LiveSession? session;

  @override
  State<TerminalTab> createState() => _TerminalTabState();
}

class _TerminalTabState extends State<TerminalTab> {
  late final DockController _dock = context.read<DockController>();

  TerminalDeck get _deck => _dock.terminals(widget.machine.id);

  TerminalSession _newSession() {
    final machine = widget.machine;
    final cwd = widget.session?.cwd;
    final runtime = context.read<SessionsProvider>().runtimeFor(machine);
    return TerminalSession(
      title: machine.name,
      open: (columns, rows) async {
        if (machine is LocalMachine) {
          final shell = localShell(
            windows: Platform.isWindows,
            environment: Platform.environment,
            isolation: devLocalEnvironment,
          );
          return LocalTerminalBackend.start(
            shell,
            cwd: cwd ?? devLocalHome ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'],
            columns: columns,
            rows: rows,
          );
        }
        final (link, probe) = await machineAccess(runtime);
        final command = remoteShellCommand(commandShell: probe.commandShell, shell: probe.shell, cwd: cwd);
        return SshTerminalBackend.start(link, command, columns: columns, rows: rows);
      },
    );
  }

  void _open() => _deck.add(_newSession());

  void _restart(TerminalSession session) {
    final deck = _deck;
    deck.close(session);
    deck.add(_newSession());
  }

  void _zoom(double delta) => _dock.setTerminalFontSize(_dock.terminalFontSize + delta);

  @override
  Widget build(BuildContext context) {
    final t = context.t.dock.terminals;
    final deck = _deck;
    return ListenableBuilder(
      listenable: Listenable.merge([deck, _dock]),
      builder: (context, _) {
        final current = deck.current;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  Expanded(
                    child: ListView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      children: [
                        for (final (index, session) in deck.sessions.indexed)
                          Padding(
                            padding: const EdgeInsets.only(right: 4),
                            child: InputChip(
                              visualDensity: VisualDensity.compact,
                              label: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 140),
                                child: Text(session.title, overflow: TextOverflow.ellipsis),
                              ),
                              selected: index == deck.selectedIndex,
                              showCheckmark: false,
                              onSelected: (_) => deck.select(index),
                              deleteButtonTooltipMessage: t.close,
                              onDeleted: () => deck.close(session),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: t.smaller,
                    onPressed: _dock.terminalFontSize <= DockController.minTerminalFontSize ? null : () => _zoom(-1),
                    icon: const Icon(Icons.text_decrease, size: 20),
                  ),
                  IconButton(
                    tooltip: t.larger,
                    onPressed: _dock.terminalFontSize >= DockController.maxTerminalFontSize ? null : () => _zoom(1),
                    icon: const Icon(Icons.text_increase, size: 20),
                  ),
                  IconButton(tooltip: t.newTerminal, onPressed: _open, icon: const Icon(Icons.add)),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: current == null
                  ? DockEmptyState(
                      icon: Icons.terminal,
                      message: t.empty(machine: widget.machine.name),
                      action: FilledButton.tonalIcon(
                        onPressed: _open,
                        icon: const Icon(Icons.add),
                        label: Text(t.newTerminal),
                      ),
                    )
                  : _TerminalPane(
                      key: ObjectKey(current),
                      session: current,
                      fontSize: _dock.terminalFontSize,
                      onRestart: () => _restart(current),
                      onClose: () => deck.close(current),
                      onZoom: _zoom,
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _TerminalPane extends StatefulWidget {
  const _TerminalPane({
    super.key,
    required this.session,
    required this.fontSize,
    required this.onRestart,
    required this.onClose,
    required this.onZoom,
  });

  final TerminalSession session;
  final double fontSize;
  final VoidCallback onRestart;
  final VoidCallback onClose;
  final void Function(double delta) onZoom;

  @override
  State<_TerminalPane> createState() => _TerminalPaneState();
}

class _TerminalPaneState extends State<_TerminalPane> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _copy() async {
    final text = widget.session.selectedText();
    if (text == null || text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
    widget.session.controller.clearSelection();
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) widget.session.terminal.paste(text);
    _focus.requestFocus();
  }

  Future<void> _menu(Offset position) async {
    final t = context.t.dock.terminals;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final hasSelection = widget.session.controller.selectionFor(widget.session.terminal.buffer) != null;
    final action = await showMenu<_PaneAction>(
      context: context,
      position: RelativeRect.fromRect(position & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        PopupMenuItem(value: _PaneAction.copy, enabled: hasSelection, child: Text(context.t.common.copy)),
        PopupMenuItem(value: _PaneAction.paste, child: Text(t.paste)),
        PopupMenuItem(value: _PaneAction.selectAll, child: Text(t.selectAll)),
        PopupMenuItem(value: _PaneAction.clear, child: Text(t.clear)),
      ],
    );
    switch (action) {
      case _PaneAction.copy:
        await _copy();
      case _PaneAction.paste:
        await _paste();
      case _PaneAction.selectAll:
        final terminal = widget.session.terminal;
        widget.session.controller.setSelection(
          terminal.buffer.createAnchor(0, 0),
          terminal.buffer.createAnchor(terminal.viewWidth, terminal.buffer.height - 1),
          mode: SelectionMode.line,
        );
      case _PaneAction.clear:
        widget.session.terminal.clear();
      case null:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = context.t.dock.terminals;
    final session = widget.session;
    final code = codeTextStyle(theme);
    return ListenableBuilder(
      listenable: session,
      builder: (context, _) {
        final phase = session.phase;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (phase is TerminalExited || phase is TerminalFailed)
              MaterialBanner(
                backgroundColor: phase is TerminalFailed ? theme.colorScheme.errorContainer : null,
                content: Text(
                  switch (phase) {
                    TerminalFailed(:final error) => t.failed(error: error.toString()),
                    TerminalExited(code: final code?) => t.exited(code: code.toString()),
                    _ => t.exitedBySignal,
                  },
                ),
                actions: [
                  TextButton(onPressed: widget.onClose, child: Text(t.close)),
                  TextButton(onPressed: widget.onRestart, child: Text(t.restart)),
                ],
              ),
            if (phase is TerminalStarting) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.equal, meta: true): () => widget.onZoom(1),
                  const SingleActivator(LogicalKeyboardKey.minus, meta: true): () => widget.onZoom(-1),
                  const SingleActivator(LogicalKeyboardKey.equal, control: true, shift: true): () => widget.onZoom(1),
                  const SingleActivator(LogicalKeyboardKey.minus, control: true, shift: true): () => widget.onZoom(-1),
                },
                child: TerminalView(
                  session.terminal,
                  controller: session.controller,
                  focusNode: _focus,
                  autofocus: true,
                  theme: terminalTheme(theme),
                  textStyle: TerminalStyle(fontSize: widget.fontSize, fontFamily: code.fontFamily ?? 'monospace'),
                  padding: const EdgeInsets.all(6),
                  keyboardAppearance: theme.brightness,
                  deleteDetection: Platform.isAndroid || Platform.isIOS,
                  readOnly: phase is! TerminalRunning && phase is! TerminalStarting,
                  onSecondaryTapDown: (details, _) => _menu(details.globalPosition),
                  onHyperlinkTap: (uri) => unawaited(launchUrl(Uri.parse(uri))),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

enum _PaneAction { copy, paste, selectAll, clear }

/// The terminal's colours: Material 3 surface, text, cursor and selection; an ANSI palette that reads on the
/// surface's brightness.
TerminalTheme terminalTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  final dark = theme.brightness == Brightness.dark;
  Color c(int value) => Color(value);
  return TerminalTheme(
    cursor: scheme.primary,
    selection: scheme.primary.withValues(alpha: 0.35),
    foreground: scheme.onSurface,
    background: scheme.surfaceContainerLowest,
    black: dark ? c(0xFF1E1E1E) : c(0xFF000000),
    red: dark ? c(0xFFF14C4C) : c(0xFFCD3131),
    green: dark ? c(0xFF23D18B) : c(0xFF107C10),
    yellow: dark ? c(0xFFE5E510) : c(0xFF949800),
    blue: dark ? c(0xFF3B8EEA) : c(0xFF0451A5),
    magenta: dark ? c(0xFFD670D6) : c(0xFFBC05BC),
    cyan: dark ? c(0xFF29B8DB) : c(0xFF0598BC),
    white: dark ? c(0xFFCCCCCC) : c(0xFF555555),
    brightBlack: dark ? c(0xFF808080) : c(0xFF666666),
    brightRed: dark ? c(0xFFFF6B6B) : c(0xFFCD3131),
    brightGreen: dark ? c(0xFF5AF7B0) : c(0xFF14CE14),
    brightYellow: dark ? c(0xFFF5F543) : c(0xFFB5BA00),
    brightBlue: dark ? c(0xFF6CB6FF) : c(0xFF0451A5),
    brightMagenta: dark ? c(0xFFE58FE5) : c(0xFFBC05BC),
    brightCyan: dark ? c(0xFF5FD7F5) : c(0xFF0598BC),
    brightWhite: dark ? c(0xFFFFFFFF) : c(0xFFA5A5A5),
    searchHitBackground: scheme.tertiaryContainer,
    searchHitBackgroundCurrent: scheme.tertiary,
    searchHitForeground: scheme.onTertiaryContainer,
  );
}
