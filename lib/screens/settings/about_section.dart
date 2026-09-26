import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../external_links.dart';

/// The app mark the About section and the licence page show.
const _glyphAsset = 'assets/ompanion.png';

/// The app's own repository and the pages a store review looks for; `LICENSE-EXCEPTION.md` is the reason the
/// GPL-3.0 build may ship through the App Store.
final Uri _sourceUrl = Uri.parse('https://github.com/edde746/ompanion');
final Uri _issuesUrl = Uri.parse('https://github.com/edde746/ompanion/issues');
final Uri _privacyPolicyUrl = Uri.parse('https://ompanion.app/privacy');
final Uri _licenseUrl = Uri.parse('https://github.com/edde746/ompanion/blob/main/LICENSE-EXCEPTION.md');

/// The agent this app is a client for.
final Uri _ompUrl = Uri.parse('https://github.com/can1357/oh-my-pi');

/// The version line: the version with the build number, which every platform but a bare test host reports.
String _versionLine(Translations t, PackageInfo info) => info.buildNumber.isEmpty
    ? t.settings.aboutVersion(version: info.version)
    : t.settings.aboutVersionBuild(version: info.version, build: info.buildNumber);

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
        _AboutCard(
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
                            _versionLine(t, info),
                            style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            _LinkRow(
              label: s.aboutClient,
              trailing: Icons.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _ompUrl)),
            ),
          ],
        ),
        const SizedBox(height: AppSizes.gap),
        _AboutCard(
          children: [
            _LinkRow(
              label: s.aboutPrivacy,
              trailing: Icons.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _privacyPolicyUrl)),
            ),
            _LinkRow(
              label: s.aboutSource,
              trailing: Icons.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _sourceUrl)),
            ),
            _LinkRow(
              label: s.aboutIssues,
              trailing: Icons.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _issuesUrl)),
            ),
            _LinkRow(
              label: s.aboutLicense,
              detail: s.aboutLicenseValue,
              trailing: Icons.open_in_new,
              onTap: () => unawaited(openExternalLink(context, _licenseUrl)),
            ),
            _LinkRow(
              label: s.aboutLicenses,
              trailing: Icons.chevron_right,
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

/// A `surfaceContainer` block with `cardRadius`, the About section's grouping: a [Material] so the ink of the
/// rows inside it lands on the block's own tone.
class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surfaceContainer,
    borderRadius: BorderRadius.circular(AppSizes.cardRadius),
    clipBehavior: Clip.antiAlias,
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
  );
}

/// One link in the About section: the label, an optional muted line under it, and a 16 px mark at the end.
/// A control tall with 4 px insets above and below its text, and taller when the label wraps or a detail line
/// takes the second line, so no label is ever cut. No start icon, no divider: the row is the whole target.
class _LinkRow extends StatelessWidget {
  const _LinkRow({required this.label, this.detail, required this.trailing, required this.onTap});

  final String label;
  final String? detail;
  final IconData trailing;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: ConstrainedBox(
          // One control tall with the 4 px insets: a 20 px line box, or two of them.
          constraints: const BoxConstraints(minHeight: AppSizes.control - 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: theme.textTheme.bodyMedium),
                    if (detail case final detail?)
                      Text(detail, style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
                  ],
                ),
              ),
              const SizedBox(width: AppSizes.gap),
              Icon(trailing, size: 16, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}
