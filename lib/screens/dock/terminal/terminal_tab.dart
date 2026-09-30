import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';
import 'package:xterm2/xterm.dart';

import '../../../app/dev_overrides.dart';
import '../../../app/palette.dart';
import '../../../app/theme.dart';
import '../../../i18n/strings.g.dart';
import '../../../models/machine.dart';
import '../../../sessions/sessions_provider.dart';
import '../../../terminal/shell_launch.dart';
import '../../../terminal/terminal_deck.dart';
import '../../../terminal/terminal_session.dart';
import '../../../widgets/activity_mark.dart';
import '../../chat/transcript/code_style.dart';
import '../../external_links.dart';
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
          // Flatpak sets SHELL to the runtime's /bin/sh; the user's shell is the one the host's user database names.
          final environment = inFlatpak ? ({...Platform.environment}..remove('SHELL')) : Platform.environment;
          final shell = localShell(
            windows: Platform.isWindows,
            environment: environment,
            accountShell: Platform.isWindows || (environment['SHELL'] ?? '').startsWith('/')
                ? null
                : await accountLoginShell(macos: Platform.isMacOS, environment: environment),
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
        final launch = remoteShellLaunch(commandShell: probe.commandShell, shell: probe.shell, cwd: cwd);
        return SshTerminalBackend.start(link, launch, columns: columns, rows: rows);
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
              height: AppSizes.control + 8,
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
                            child: _TerminalTabButton(
                              title: session.title,
                              selected: index == deck.selectedIndex,
                              closeTooltip: t.close,
                              onSelect: () => deck.select(index),
                              onClose: () => deck.close(session),
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: t.smaller,
                    onPressed: _dock.terminalFontSize <= DockController.minTerminalFontSize ? null : () => _zoom(-1),
                    icon: const Icon(Symbols.text_decrease, size: 20),
                  ),
                  IconButton(
                    tooltip: t.larger,
                    onPressed: _dock.terminalFontSize >= DockController.maxTerminalFontSize ? null : () => _zoom(1),
                    icon: const Icon(Symbols.text_increase, size: 20),
                  ),
                  IconButton(tooltip: t.newTerminal, onPressed: _open, icon: const Icon(Symbols.add)),
                ],
              ),
            ),
            Expanded(
              child: current == null
                  ? DockEmptyState(
                      icon: Symbols.terminal,
                      message: t.empty(machine: widget.machine.name),
                      action: FilledButton.tonalIcon(
                        onPressed: _open,
                        icon: const Icon(Symbols.add),
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

/// One terminal in the tab strip: its title, selected by a lighter tone, and a close button.
class _TerminalTabButton extends StatelessWidget {
  const _TerminalTabButton({
    required this.title,
    required this.selected,
    required this.closeTooltip,
    required this.onSelect,
    required this.onClose,
  });

  final String title;
  final bool selected;
  final String closeTooltip;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final foreground = selected ? scheme.onSurface : scheme.onSurfaceVariant;
    const shape = StadiumBorder();
    return Material(
      color: selected ? scheme.surfaceContainerHighest : Colors.transparent,
      shape: shape,
      child: InkWell(
        customBorder: shape,
        onTap: onSelect,
        child: SizedBox(
          height: AppSizes.control,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  title,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelLarge?.copyWith(color: foreground),
                ),
              ),
              IconButton(
                tooltip: closeTooltip,
                onPressed: onClose,
                iconSize: 16,
                style: IconButton.styleFrom(minimumSize: const Size.square(28), fixedSize: const Size.square(28)),
                color: foreground,
                icon: const Icon(Symbols.close),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
      ),
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
                backgroundColor: phase is TerminalFailed ? AppColors.of(context).errorSurface : null,
                content: Text(switch (phase) {
                  TerminalFailed(:final error) => t.failed(error: error.toString()),
                  TerminalExited(code: final code?) => t.exited(code: code.toString()),
                  _ => t.exitedBySignal,
                }),
                actions: [
                  TextButton(onPressed: widget.onClose, child: Text(t.close)),
                  TextButton(onPressed: widget.onRestart, child: Text(t.restart)),
                ],
              ),
            Expanded(
              child: CallbackShortcuts(
                bindings: {
                  const SingleActivator(LogicalKeyboardKey.equal, meta: true): () => widget.onZoom(1),
                  const SingleActivator(LogicalKeyboardKey.minus, meta: true): () => widget.onZoom(-1),
                  const SingleActivator(LogicalKeyboardKey.equal, control: true, shift: true): () => widget.onZoom(1),
                  const SingleActivator(LogicalKeyboardKey.minus, control: true, shift: true): () => widget.onZoom(-1),
                },
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    TerminalView(
                      session.terminal,
                      controller: session.controller,
                      focusNode: _focus,
                      autofocus: true,
                      theme: terminalTheme(theme),
                      textStyle: TerminalStyle(fontSize: widget.fontSize, fontFamily: code.fontFamily!),
                      padding: const EdgeInsets.all(6),
                      keyboardAppearance: theme.brightness,
                      deleteDetection: Platform.isAndroid || Platform.isIOS,
                      readOnly: phase is! TerminalRunning && phase is! TerminalStarting,
                      onSecondaryTapDown: (details, _) => _menu(details.globalPosition),
                      onHyperlinkTap: (link) {
                        final uri = Uri.tryParse(link);
                        if (uri != null) unawaited(openExternalLink(context, uri));
                      },
                    ),
                    // Where the prompt appears once the shell is up.
                    if (phase is TerminalStarting) const Positioned(left: 6, top: 6, child: ActivityMark()),
                  ],
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

/// The terminal's colours: the theme's text, background and selection tones for text, cursor, selection and search
/// hits; its 16 ANSI tokens as they are.
TerminalTheme terminalTheme(ThemeData theme) {
  final scheme = theme.colorScheme;
  final colors = AppColors.ofTheme(theme);
  return TerminalTheme(
    cursor: scheme.onSurface,
    selection: scheme.onSurface.withValues(alpha: 0.25),
    foreground: scheme.onSurface,
    background: scheme.surface,
    black: colors[ThemeToken.ansiBlack],
    red: colors[ThemeToken.ansiRed],
    green: colors[ThemeToken.ansiGreen],
    yellow: colors[ThemeToken.ansiYellow],
    blue: colors[ThemeToken.ansiBlue],
    magenta: colors[ThemeToken.ansiMagenta],
    cyan: colors[ThemeToken.ansiCyan],
    white: colors[ThemeToken.ansiWhite],
    brightBlack: colors[ThemeToken.ansiBrightBlack],
    brightRed: colors[ThemeToken.ansiBrightRed],
    brightGreen: colors[ThemeToken.ansiBrightGreen],
    brightYellow: colors[ThemeToken.ansiBrightYellow],
    brightBlue: colors[ThemeToken.ansiBrightBlue],
    brightMagenta: colors[ThemeToken.ansiBrightMagenta],
    brightCyan: colors[ThemeToken.ansiBrightCyan],
    brightWhite: colors[ThemeToken.ansiBrightWhite],
    searchHitBackground: scheme.surfaceContainerHighest,
    searchHitBackgroundCurrent: scheme.onSurfaceVariant,
    searchHitForeground: scheme.onSurface,
  );
}
