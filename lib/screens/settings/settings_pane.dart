import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../app/build_channel.dart';
import '../../i18n/strings.g.dart';
import '../../providers/settings_provider.dart';

class SettingsPane extends StatelessWidget {
  const SettingsPane({super.key});

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final settings = context.watch<SettingsProvider>();
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(t.settings.theme, style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        SegmentedButton<ThemeMode>(
          segments: [
            ButtonSegment(value: ThemeMode.system, label: Text(t.settings.themeSystem)),
            ButtonSegment(value: ThemeMode.light, label: Text(t.settings.themeLight)),
            ButtonSegment(value: ThemeMode.dark, label: Text(t.settings.themeDark)),
          ],
          selected: {settings.get(Prefs.themeMode)},
          onSelectionChanged: (selection) => settings.set(Prefs.themeMode, selection.single),
        ),
        const SizedBox(height: 24),
        ListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t.settings.buildChannel),
          subtitle: Text(BuildChannel.current.name),
        ),
      ],
    );
  }
}
