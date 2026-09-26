import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/settings/settings_pane.dart';
import 'package:ompanion/screens/shell/shortcuts.dart';

void main() {
  final t = AppLocale.en.buildSync();

  test('every app shortcut is listed once, the panel tabs as one range', () {
    final mac = shortcutList(t, appShortcuts(TargetPlatform.macOS), TargetPlatform.macOS);
    expect(mac, contains((t.settings.shortcutToggleSidebar, '⌘B')));
    expect(mac, contains((t.settings.shortcutPanelTab, '⌘1–⌘5')));
    expect(mac, contains((t.settings.shortcutAddMachine, '⇧⌘M')));
    expect(mac, contains((t.settings.shortcutAbort, 'Esc')));
    expect(mac, contains((t.settings.shortcutSearchSessions, '⌘F')));
    expect(mac.map((row) => row.$1).toSet(), hasLength(mac.length));
    expect(mac, hasLength(appShortcuts(TargetPlatform.macOS).length - 4));

    final linux = shortcutList(t, appShortcuts(TargetPlatform.linux), TargetPlatform.linux);
    expect(linux, contains((t.settings.shortcutSettings, 'Ctrl+,')));
    expect(linux, contains((t.settings.shortcutTogglePause, 'Ctrl+Shift+P')));
  });
}
