import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/theme.dart';
import '../../config/settings_schema.dart';
import '../../i18n/strings.g.dart';
import '../../utils/app_logger.dart';
import '../chat/transcript/ansi.dart';
import '../chat/transcript/code_style.dart';

/// The layer a value comes from, as a small tag. An environment variable is the one layer the files cannot
/// change, so it reads as a warning.
class ProvenanceBadge extends StatelessWidget {
  const ProvenanceBadge(this.provenance, {super.key, this.envName});

  final Provenance provenance;

  /// The environment variable, for [Provenance.env].
  final String? envName;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final scheme = Theme.of(context).colorScheme;
    final label = switch (provenance) {
      Provenance.env => t.config.provenance.env(name: envName ?? '?'),
      Provenance.runtime => t.config.provenance.runtime,
      Provenance.overlay => t.config.provenance.overlay,
      Provenance.project => t.config.provenance.project,
      Provenance.global => t.config.provenance.global,
      Provenance.defaults => t.config.provenance.defaults,
    };
    final foreground = switch (provenance) {
      Provenance.env => AppColors.of(context).warning,
      Provenance.defaults => scheme.onSurfaceVariant,
      _ => scheme.onSurface,
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
      child: ConfigTag(label, color: foreground),
    );
  }
}

/// A short status word on a tone-lighter pill: provenance, "in use", "installed".
class ConfigTag extends StatelessWidget {
  const ConfigTag(this.label, {super.key, this.color});

  final String label;

  /// Text colour; defaults to secondary text.
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh, borderRadius: BorderRadius.circular(6)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(label, style: theme.textTheme.labelSmall?.copyWith(color: color ?? theme.colorScheme.onSurfaceVariant)),
      ),
    );
  }
}

/// A flat group: a `surfaceContainer` block with the card radius.
class ConfigBlock extends StatelessWidget {
  const ConfigBlock({super.key, required this.child, this.padding = const EdgeInsets.all(12)});

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    padding: padding,
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainer,
      borderRadius: BorderRadius.circular(AppSizes.cardRadius),
    ),
    child: child,
  );
}

/// A note above content: secondary text on a flat block, or an error on the muted error surface.
class ConfigBanner extends StatelessWidget {
  const ConfigBanner(this.text, {super.key, this.error = false});

  final String text;
  final bool error;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final foreground = error ? colors.error : theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: error ? colors.errorSurface : theme.colorScheme.surfaceContainer,
        borderRadius: BorderRadius.circular(AppSizes.radius),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(error ? Icons.error_outline : Icons.info_outline, size: 16, color: foreground),
          ),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: foreground))),
        ],
      ),
    );
  }
}

/// A horizontally scrolling strip of flat pills; the selected one sits one tone lighter. Section switchers
/// and settings tabs.
class ConfigPills<T> extends StatelessWidget {
  const ConfigPills({super.key, required this.value, required this.items, required this.onChanged, this.padding = EdgeInsets.zero});

  final T value;
  final List<(T value, String label, IconData? icon)> items;
  final ValueChanged<T> onChanged;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final radius = BorderRadius.circular(AppSizes.radius);
    return SizedBox(
      height: AppSizes.control,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        children: [
          for (final (item, label, icon) in items)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Material(
                color: item == value ? scheme.surfaceContainerHighest : Colors.transparent,
                borderRadius: radius,
                child: InkWell(
                  borderRadius: radius,
                  onTap: item == value ? null : () => onChanged(item),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (icon != null) ...[
                          Icon(icon, size: 16, color: item == value ? scheme.onSurface : scheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                        ],
                        Text(
                          label,
                          style: theme.textTheme.labelLarge?.copyWith(color: item == value ? scheme.onSurface : scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A small heading inside a page's list.
class ConfigSectionTitle extends StatelessWidget {
  const ConfigSectionTitle(this.text, {super.key, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 8),
      child: SizedBox(
        height: trailing == null ? null : AppSizes.control,
        child: Row(
          children: [
            Expanded(child: Text(text, style: theme.textTheme.titleSmall)),
            ?trailing,
          ],
        ),
      ),
    );
  }
}

/// ANSI text from omp (`command_output`, CLI output), selectable, in a monospace block as tall as its text.
class CommandOutputView extends StatelessWidget {
  const CommandOutputView(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodySmall!.fontSize, height: 1.35);
    return ConfigBlock(
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: SelectableText.rich(ansiSpan(text, base: base, scheme: theme.colorScheme)),
            ),
          ),
          IconButton(
            tooltip: context.t.common.copy,
            icon: const Icon(Icons.copy, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 28, height: 28),
            onPressed: () => Clipboard.setData(ClipboardData(text: text.replaceAll(RegExp(r'\x1B\[[0-9;?]*[A-Za-z]'), ''))),
          ),
        ],
      ),
    );
  }
}

/// The command a page ran, a spinner while it runs, and its output.
class CommandRun extends StatelessWidget {
  const CommandRun({super.key, required this.command, required this.running, this.output});

  final String command;
  final bool running;
  final String? output;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(command, style: codeTextStyle(theme).copyWith(fontSize: theme.textTheme.labelMedium?.fontSize, color: theme.colorScheme.onSurfaceVariant)),
              ),
              if (running) const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          if (output != null) ...[
            const SizedBox(height: 6),
            CommandOutputView(output!.isEmpty ? context.t.config.noOutput : output!),
          ],
        ],
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
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText('$error', style: TextStyle(color: AppColors.of(context).error)),
          if (onRetry != null) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(onPressed: onRetry, icon: const Icon(Icons.refresh, size: 18), label: Text(context.t.common.retry)),
          ],
        ],
      ),
    );
  }
}

/// A page title row with trailing actions, and an optional secondary line under it.
class ConfigHeader extends StatelessWidget {
  const ConfigHeader({super.key, required this.title, this.subtitle, this.actions = const []});

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.titleMedium),
                if (subtitle != null)
                  Text(subtitle!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          for (final (index, action) in actions.indexed) ...[if (index > 0) const SizedBox(width: AppSizes.gap), action],
        ],
      ),
    );
  }
}

/// The refresh button of a page; a spinner takes the icon's place while the page loads.
class RefreshAction extends StatelessWidget {
  const RefreshAction({super.key, required this.loading, required this.onPressed});

  final bool loading;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: context.t.config.refresh,
    onPressed: loading ? null : onPressed,
    icon: loading ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
  );
}

/// Runs [action], shows its failure as a snack bar, and returns whether it succeeded. Failures are logged
/// unless [secret]: errors about a secret value may quote it.
Future<bool> runReporting(BuildContext context, Future<void> Function() action, {String? done, bool secret = false}) async {
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = AppColors.of(context).error;
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
