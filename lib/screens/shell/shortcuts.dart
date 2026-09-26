import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../models/dock_tab.dart';

final class ToggleSidebarIntent extends Intent {
  const ToggleSidebarIntent();
}

final class TogglePanelsIntent extends Intent {
  const TogglePanelsIntent();
}

final class ShowPanelTabIntent extends Intent {
  const ShowPanelTabIntent(this.tab);

  final DockTab tab;
}

final class AddMachineIntent extends Intent {
  const AddMachineIntent();
}

final class OpenSettingsIntent extends Intent {
  const OpenSettingsIntent();
}

final class NewSessionIntent extends Intent {
  const NewSessionIntent();
}

/// Pause or resume the shown session (companion `pause.set`).
final class TogglePauseIntent extends Intent {
  const TogglePauseIntent();
}

/// Open the composer's command palette.
final class OpenPaletteIntent extends Intent {
  const OpenPaletteIntent();
}

/// Focus the sidebar's session search.
final class SearchSessionsIntent extends Intent {
  const SearchSessionsIntent();
}

/// Abort the shown session's run, as Esc does in the TUI.
final class AbortRunIntent extends Intent {
  const AbortRunIntent();
}

const _digits = [
  LogicalKeyboardKey.digit1,
  LogicalKeyboardKey.digit2,
  LogicalKeyboardKey.digit3,
  LogicalKeyboardKey.digit4,
  LogicalKeyboardKey.digit5,
];

/// App-wide key bindings: Cmd on Apple platforms, Ctrl elsewhere. Each layout binds the intents to actions.
Map<ShortcutActivator, Intent> appShortcuts(TargetPlatform platform) {
  final apple = platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  SingleActivator primary(LogicalKeyboardKey key, {bool shift = false}) =>
      SingleActivator(key, meta: apple, control: !apple, shift: shift);
  return {
    primary(LogicalKeyboardKey.keyB): const ToggleSidebarIntent(),
    primary(LogicalKeyboardKey.keyJ): const TogglePanelsIntent(),
    for (final (index, tab) in DockTab.values.indexed) primary(_digits[index]): ShowPanelTabIntent(tab),
    primary(LogicalKeyboardKey.keyM, shift: true): const AddMachineIntent(),
    primary(LogicalKeyboardKey.comma): const OpenSettingsIntent(),
    primary(LogicalKeyboardKey.keyN): const NewSessionIntent(),
    primary(LogicalKeyboardKey.keyP, shift: true): const TogglePauseIntent(),
    primary(LogicalKeyboardKey.keyK): const OpenPaletteIntent(),
    primary(LogicalKeyboardKey.keyF): const SearchSessionsIntent(),
    const SingleActivator(LogicalKeyboardKey.escape): const AbortRunIntent(),
  };
}
