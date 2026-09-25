import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../app/build_channel.dart';
import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/app_segmented.dart';
import '../shell/shortcuts.dart';

class SettingsPane extends StatelessWidget {
  const SettingsPane({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    final platform = theme.platform;
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(t.settings.theme, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSizes.gap),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppSegmented<ThemeMode>(
            value: settings.get(Prefs.themeMode),
            segments: [
              (ThemeMode.system, t.settings.themeSystem, null),
              (ThemeMode.light, t.settings.themeLight, null),
              (ThemeMode.dark, t.settings.themeDark, null),
            ],
            onChanged: (mode) => settings.set(Prefs.themeMode, mode),
          ),
        ),
        const SizedBox(height: 24),
        Text(t.settings.buildChannel, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(BuildChannel.current.name, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        const SizedBox(height: 24),
        Text(t.settings.shortcuts, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSizes.gap),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainer,
            borderRadius: BorderRadius.circular(AppSizes.cardRadius),
          ),
          child: Column(
            children: [
              for (final (label, keys) in shortcutList(t, appShortcuts(platform), platform))
                SizedBox(
                  height: AppSizes.rowHeight,
                  child: Row(
                    children: [
                      Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
                      Text(
                        keys,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// What [bindings] do and their keys, in binding order; the panel-tab keys share one row (`⌘1–⌘5`).
List<(String, String)> shortcutList(Translations t, Map<ShortcutActivator, Intent> bindings, TargetPlatform platform) {
  final apple = platform == TargetPlatform.macOS || platform == TargetPlatform.iOS;
  final s = t.settings;
  final rows = <(String, String)>[];
  final tabKeys = <String>[];
  for (final MapEntry(key: activator, value: intent) in bindings.entries) {
    final keys = _keys(activator as SingleActivator, apple: apple);
    final label = switch (intent) {
      ToggleSidebarIntent() => s.shortcutToggleSidebar,
      TogglePanelsIntent() => s.shortcutTogglePanels,
      ShowPanelTabIntent() => null,
      AddMachineIntent() => s.shortcutAddMachine,
      OpenSettingsIntent() => s.shortcutSettings,
      NewSessionIntent() => s.shortcutNewSession,
      TogglePauseIntent() => s.shortcutTogglePause,
      OpenPaletteIntent() => s.shortcutPalette,
      AbortRunIntent() => s.shortcutAbort,
      _ => throw StateError('no label for $intent'),
    };
    if (label != null) {
      rows.add((label, keys));
    } else {
      if (tabKeys.isEmpty) rows.add((s.shortcutPanelTab, ''));
      tabKeys.add(keys);
    }
  }
  if (tabKeys.isEmpty) return rows;
  final index = rows.indexWhere((row) => row.$1 == s.shortcutPanelTab);
  rows[index] = (s.shortcutPanelTab, tabKeys.length == 1 ? tabKeys.single : '${tabKeys.first}–${tabKeys.last}');
  return rows;
}

String _keys(SingleActivator activator, {required bool apple}) {
  final key = switch (activator.trigger) {
    LogicalKeyboardKey.escape => 'Esc',
    final trigger => trigger.keyLabel.toUpperCase(),
  };
  if (apple) {
    return [if (activator.control) '⌃', if (activator.alt) '⌥', if (activator.shift) '⇧', if (activator.meta) '⌘', key].join();
  }
  return [if (activator.control) 'Ctrl', if (activator.alt) 'Alt', if (activator.shift) 'Shift', if (activator.meta) 'Meta', key]
      .join('+');
}
