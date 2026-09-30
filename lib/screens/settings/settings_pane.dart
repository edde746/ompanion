import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../app/build_channel.dart';
import '../../app/palette.dart';
import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/app_segmented.dart';
import '../shell/shortcuts.dart';
import 'about_section.dart';
import 'notifications_section.dart';
import 'settings_card.dart';
import 'theme_editor_screen.dart';

class SettingsPane extends StatelessWidget {
  const SettingsPane({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    final platform = theme.platform;
    final mode = settings.get(Prefs.themeMode);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(t.settings.theme, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSizes.gap),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppSegmented<AppThemeMode>(
            value: mode,
            segments: [
              (AppThemeMode.system, t.settings.themeSystem, null),
              (AppThemeMode.light, t.settings.themeLight, null),
              (AppThemeMode.dark, t.settings.themeDark, null),
              (AppThemeMode.custom, t.settings.themeCustom, null),
            ],
            onChanged: (mode) async {
              // The first custom theme starts from the one on screen, so nothing changes until a colour is picked.
              if (mode == AppThemeMode.custom && !settings.isSet(Prefs.customTheme)) {
                await settings.set(
                  Prefs.customTheme,
                  theme.brightness == Brightness.dark ? AppPalette.dark : AppPalette.light,
                );
              }
              await settings.set(Prefs.themeMode, mode);
            },
          ),
        ),
        if (mode == AppThemeMode.custom) ...[
          const SizedBox(height: AppSizes.gap),
          SettingsCard(
            children: [
              SettingsLinkRow(
                label: t.settings.editColors,
                detail: _customSummary(t, settings.get(Prefs.customTheme)),
                trailing: Symbols.chevron_right,
                onTap: () => openThemeEditor(context),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        const NotificationsSection(),
        const SizedBox(height: 24),
        Text(t.settings.buildChannel, style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          BuildChannel.current.name,
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
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
        const SizedBox(height: 24),
        const AboutSection(),
      ],
    );
  }
}

/// `Dark base`, or `Dark base · 3 changed` once colours are picked.
String _customSummary(Translations t, AppPalette palette) {
  final base = switch (palette.base) {
    ThemeBase.dark => t.settings.themeDark,
    ThemeBase.light => t.settings.themeLight,
  };
  return palette.picks.isEmpty
      ? t.settings.customBase(base: base)
      : t.settings.customPicked(base: base, count: palette.picks.length);
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
      SearchSessionsIntent() => s.shortcutSearchSessions,
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
    return [
      if (activator.control) '⌃',
      if (activator.alt) '⌥',
      if (activator.shift) '⇧',
      if (activator.meta) '⌘',
      key,
    ].join();
  }
  return [
    if (activator.control) 'Ctrl',
    if (activator.alt) 'Alt',
    if (activator.shift) 'Shift',
    if (activator.meta) 'Meta',
    key,
  ].join('+');
}
