import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../config/settings_schema.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../chat/transcript/ansi.dart';

/// The layer a value comes from, as a small chip.
class ProvenanceBadge extends StatelessWidget {
  const ProvenanceBadge(this.provenance, {super.key, this.envName});

  final Provenance provenance;

  /// The environment variable, for [Provenance.env].
  final String? envName;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final (label, background, foreground) = switch (provenance) {
      Provenance.env => (t.config.provenance.env(name: envName ?? '?'), scheme.errorContainer, scheme.onErrorContainer),
      Provenance.runtime => (t.config.provenance.runtime, scheme.tertiaryContainer, scheme.onTertiaryContainer),
      Provenance.overlay => (t.config.provenance.overlay, scheme.tertiaryContainer, scheme.onTertiaryContainer),
      Provenance.project => (t.config.provenance.project, scheme.secondaryContainer, scheme.onSecondaryContainer),
      Provenance.global => (t.config.provenance.global, scheme.primaryContainer, scheme.onPrimaryContainer),
      Provenance.defaults => (t.config.provenance.defaults, scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };
    return Tooltip(
      message: switch (provenance) {
        Provenance.env => t.config.provenance.envHint(name: envName ?? '?'),
        Provenance.runtime => t.config.provenance.runtimeHint,
        Provenance.overlay => t.config.provenance.overlayHint,
        Provenance.project => t.config.provenance.projectHint,
        Provenance.global => t.config.provenance.globalHint,
        Provenance.defaults => t.config.provenance.defaultsHint,
      },
      child: DecoratedBox(
        decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(6)),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: foreground)),
        ),
      ),
    );
  }
}

/// ANSI text from omp (`command_output`, CLI output), selectable, in a monospace block.
class CommandOutputView extends StatelessWidget {
  const CommandOutputView(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall!.copyWith(fontFamily: 'monospace', height: 1.35);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: SelectableText.rich(ansiSpan(text, base: base, scheme: theme.colorScheme))),
            IconButton(
              tooltip: context.t.common.copy,
              icon: const Icon(Icons.copy, size: 18),
              onPressed: () => Clipboard.setData(ClipboardData(text: text.replaceAll(RegExp(r'\x1B\[[0-9;?]*[A-Za-z]'), ''))),
            ),
          ],
        ),
      ),
    );
  }
}

/// A failure shown in place of content, with a retry.
class ConfigError extends StatelessWidget {
  const ConfigError(this.error, {super.key, this.onRetry});

  final Object error;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('$error', style: TextStyle(color: theme.colorScheme.error)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            OutlinedButton.icon(onPressed: onRetry, icon: const Icon(Icons.refresh), label: Text(context.t.common.retry)),
          ],
        ],
      ),
    );
  }
}

/// A page title row with trailing actions.
class ConfigHeader extends StatelessWidget {
  const ConfigHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleLarge),
                if (subtitle != null)
                  Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          ...actions,
        ],
      ),
    );
  }
}

/// Runs [action], shows its failure as a snack bar, and returns whether it succeeded. Failures are logged
/// unless [secret]: errors about a secret value may quote it.
Future<bool> runReporting(BuildContext context, Future<void> Function() action, {String? done, bool secret = false}) async {
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = Theme.of(context).colorScheme.error;
  try {
    await action();
    if (done != null) messenger.showSnackBar(SnackBar(content: Text(done)));
    return true;
  } on Object catch (error) {
    if (!secret) appLogger.w('config action failed', error: error);
    messenger.showSnackBar(
      SnackBar(
        content: Text('$error', style: TextStyle(color: errorColor)),
        duration: const Duration(seconds: 8),
      ),
    );
    return false;
  }
}

/// Asks a yes/no question; true when confirmed.
Future<bool> confirmAction(BuildContext context, {required String title, required String body, required String action}) async {
  final t = context.t;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
      ],
    ),
  );
  return confirmed ?? false;
}
