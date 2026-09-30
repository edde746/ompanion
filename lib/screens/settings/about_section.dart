import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../external_links.dart';
import 'settings_card.dart';

/// The app mark the About section and the licence page show.
const _glyphAsset = 'assets/ompanion.png';

/// The app's own repository and the pages a store review looks for.
final Uri _sourceUrl = Uri.parse('https://github.com/edde746/ompanion');
final Uri _issuesUrl = Uri.parse('https://github.com/edde746/ompanion/issues');
final Uri _privacyPolicyUrl = Uri.parse('https://ompanion.app/privacy');
final Uri _licenseUrl = Uri.parse('https://github.com/edde746/ompanion/blob/main/LICENSE');

/// The agent this app is a client for.
final Uri _ompUrl = Uri.parse('https://github.com/can1357/oh-my-pi');

/// The About section of the settings pane: the app's mark, the version the running build reports and the links
/// a reviewer looks for, the privacy policy (App Review guideline 5.1.1(i)) among them.
///
/// Every link leaves through [openExternalLink]. "Open-source licenses" opens Flutter's `showLicensePage`,
/// which lists the licences of every bundled package.
class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  /// The running build's metadata, from the platform; null until it answers and on one that never does.
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final info = await PackageInfo.fromPlatform();
      if (mounted) setState(() => _info = info);
    } on Object catch (error) {
      // A platform with nothing to report leaves the version line out; the links still work.
      appLogger.w('no package info for the About section: $error');
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final s = t.settings;
    final info = _info;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(s.about, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSizes.gap),
        SettingsCard(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Image.asset(_glyphAsset, width: 28, height: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.app.title, style: theme.textTheme.titleMedium),
                        if (info != null)
                          Text(
                            t.settings.aboutVersion(version: info.version, build: info.buildNumber),
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SettingsLinkRow(
              label: s.aboutClient,
              trailing: Symbols.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _ompUrl)),
            ),
          ],
        ),
        const SizedBox(height: AppSizes.gap),
        SettingsCard(
          children: [
            SettingsLinkRow(
              label: s.aboutPrivacy,
              trailing: Symbols.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _privacyPolicyUrl)),
            ),
            SettingsLinkRow(
              label: s.aboutSource,
              trailing: Symbols.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _sourceUrl)),
            ),
            SettingsLinkRow(
              label: s.aboutIssues,
              trailing: Symbols.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _issuesUrl)),
            ),
            SettingsLinkRow(
              label: s.aboutLicense,
              detail: s.aboutLicenseValue,
              trailing: Symbols.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _licenseUrl)),
            ),
            SettingsLinkRow(
              label: s.aboutLicenses,
              trailing: Symbols.chevron_right,
              onTap: () => showLicensePage(
                context: context,
                applicationName: t.app.title,
                applicationVersion: info?.version,
                applicationIcon: Image.asset(_glyphAsset, width: 48, height: 48),
                applicationLegalese: s.aboutLicenseValue,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
