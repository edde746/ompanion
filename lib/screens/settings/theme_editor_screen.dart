import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../app/palette.dart';
import '../../app/theme.dart';
import '../../app/window_chrome.dart';
import '../../i18n/strings.g.dart';
import '../../providers/settings_provider.dart';
import '../../widgets/activity_mark.dart';
import '../../widgets/app_segmented.dart';
import '../chat/transcript/code_style.dart';
import 'color_picker.dart';
import 'settings_card.dart';

Future<void> openThemeEditor(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ThemeEditorScreen()));

/// The Custom theme's tokens, each with its picker, beside a preview drawn in the theme (docs/design.md, Theme editor).
/// The page itself stays in the built-in theme of the custom theme's brightness, so no pick hides its own controls.
class ThemeEditorScreen extends StatefulWidget {
  const ThemeEditorScreen({super.key});

  @override
  State<ThemeEditorScreen> createState() => _ThemeEditorScreenState();
}

class _ThemeEditorScreenState extends State<ThemeEditorScreen> {
  /// The palette on screen: the stored one plus a pick being dragged.
  late AppPalette _draft;
  ThemeToken? _open;

  @override
  void initState() {
    super.initState();
    _draft = context.read<SettingsProvider>().get(Prefs.customTheme);
  }

  void _save(AppPalette palette) {
    setState(() => _draft = palette);
    unawaited(context.read<SettingsProvider>().set(Prefs.customTheme, palette));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return Theme(
      data: _draft.brightness == Brightness.dark ? darkAppTheme : lightAppTheme,
      child: Builder(
        builder: (context) => Scaffold(
          appBar: windowAppBar(
            context,
            title: Text(t.themeEditor.title),
            actions: [
              TextButton(
                onPressed: _draft.picks.isEmpty ? null : () => _save(AppPalette(_draft.base)),
                child: Text(t.themeEditor.resetAll),
              ),
              const SizedBox(width: AppSizes.gap),
            ],
          ),
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final list = _tokenList(context);
                final preview = _Preview(palette: _draft);
                if (constraints.maxWidth >= 840) {
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(child: list),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
                        child: SizedBox(width: 320, child: preview),
                      ),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                      child: SizedBox(height: 240, child: preview),
                    ),
                    Expanded(child: list),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _tokenList(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(t.themeEditor.startFrom, style: theme.textTheme.titleMedium),
        const SizedBox(height: AppSizes.gap),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: AppSegmented<ThemeBase>(
            value: _draft.base,
            segments: [(ThemeBase.dark, t.settings.themeDark, null), (ThemeBase.light, t.settings.themeLight, null)],
            onChanged: (base) => _save(AppPalette(base, _draft.picks)),
          ),
        ),
        for (final group in TokenGroup.values) ...[
          const SizedBox(height: 24),
          Text(t.themeEditor.groups[group.name]!, style: theme.textTheme.titleMedium),
          if (group == TokenGroup.terminal) ...[
            const SizedBox(height: 4),
            Text(t.themeEditor.terminalNote, style: muted),
          ],
          const SizedBox(height: AppSizes.gap),
          SettingsCard(
            children: [
              for (final token in ThemeToken.values)
                if (token.group == group)
                  _TokenRow(
                    token: token,
                    color: _draft[token],
                    picked: _draft.picks.containsKey(token),
                    open: _open == token,
                    onTap: () => setState(() => _open = _open == token ? null : token),
                    onChanged: (color) => setState(() => _draft = _draft.pick(token, color)),
                    onChangeEnd: (color) => _save(_draft.pick(token, color)),
                    onReset: () => _save(_draft.reset(token)),
                  ),
            ],
          ),
        ],
      ],
    );
  }
}

/// A token: its swatch, name and use, its hex, and a reset while it differs from the base; open, its picker under it.
class _TokenRow extends StatelessWidget {
  const _TokenRow({
    required this.token,
    required this.color,
    required this.picked,
    required this.open,
    required this.onTap,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onReset,
  });

  final ThemeToken token;
  final Color color;
  final bool picked;
  final bool open;
  final VoidCallback onTap;
  final ValueChanged<Color> onChanged;
  final ValueChanged<Color> onChangeEnd;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final t = context.t.themeEditor;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: AppSizes.control - 8),
              child: Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
                    child: const SizedBox.square(dimension: 24),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(t.names[token.name]!, style: theme.textTheme.bodyMedium),
                        Text(
                          t.uses[token.name]!,
                          style: theme.textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSizes.gap),
                  Text(colorHex(color), style: codeTextStyle(theme).copyWith(color: scheme.onSurfaceVariant)),
                  const SizedBox(width: 4),
                  SizedBox.square(
                    dimension: 32,
                    child: picked
                        ? IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 18,
                            tooltip: t.reset,
                            color: scheme.onSurfaceVariant,
                            onPressed: onReset,
                            icon: const Icon(Symbols.restart_alt),
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (open)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: ColorPicker(color: color, onChanged: onChanged, onChangeEnd: onChangeEnd),
          ),
      ],
    );
  }
}

/// Every token at work, drawn in [palette]'s own theme. It does not take input.
class _Preview extends StatefulWidget {
  const _Preview({required this.palette});

  final AppPalette palette;

  @override
  State<_Preview> createState() => _PreviewState();
}

class _PreviewState extends State<_Preview> {
  late ThemeData _theme = appTheme(widget.palette);

  @override
  void didUpdateWidget(_Preview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.palette != oldWidget.palette) _theme = appTheme(widget.palette);
  }

  @override
  Widget build(BuildContext context) => Theme(
    data: _theme,
    child: Builder(builder: _build),
  );

  Widget _build(BuildContext context) {
    final t = context.t.themeEditor.preview;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final colors = AppColors.of(context);
    final body = theme.textTheme.bodyMedium;
    final small = theme.textTheme.bodySmall;
    final code = codeTextStyle(theme);
    final radius = BorderRadius.circular(AppSizes.radius);
    Widget block(Color color, Widget child, {EdgeInsets padding = const EdgeInsets.all(8)}) => DecoratedBox(
      decoration: BoxDecoration(color: color, borderRadius: radius),
      child: Padding(padding: padding, child: child),
    );
    Widget status(Widget mark, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        mark,
        const SizedBox(width: 6),
        Text(label, style: small?.copyWith(color: scheme.onSurfaceVariant)),
      ],
    );
    Widget dot(Color color) => DecoratedBox(
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: const SizedBox.square(dimension: 8),
    );
    const gap = SizedBox(height: AppSizes.gap);
    return IgnorePointer(
      child: Material(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(AppSizes.cardRadius),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ColoredBox(
                color: scheme.surfaceContainerLow,
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Text(t.session, style: body),
                      ),
                      block(
                        scheme.surfaceContainerHighest,
                        Text(t.selected, style: body),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                      ),
                    ],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(t.text, style: body),
                    Text(t.muted, style: body?.copyWith(color: scheme.onSurfaceVariant)),
                    gap,
                    DecoratedBox(
                      decoration: BoxDecoration(
                        color: scheme.surfaceContainer,
                        borderRadius: BorderRadius.circular(AppSizes.cardRadius),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            TextField(decoration: InputDecoration(hintText: t.field)),
                            gap,
                            Row(
                              children: [
                                FilledButton.tonal(onPressed: () {}, child: Text(t.secondary)),
                                const SizedBox(width: AppSizes.gap),
                                FilledButton(onPressed: () {}, child: Text(t.primary)),
                                const Spacer(),
                                Switch(value: true, onChanged: (_) {}),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                    gap,
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: block(scheme.surfaceBright, Text(t.menuItem, style: body)),
                    ),
                    gap,
                    Wrap(
                      spacing: 12,
                      runSpacing: 4,
                      children: [
                        status(dot(colors.success), t.done),
                        status(dot(colors.warning), t.paused),
                        status(dot(colors.error), t.failed),
                        status(ActivityMark(color: colors.running), t.working),
                      ],
                    ),
                    gap,
                    block(colors.errorSurface, Text(t.error, style: small?.copyWith(color: colors.error))),
                    gap,
                    ClipRRect(
                      borderRadius: radius,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          ColoredBox(
                            color: colors.diffAddSurface,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              child: Text('+ limit = 3;', style: code.copyWith(color: colors.diffAdd)),
                            ),
                          ),
                          ColoredBox(
                            color: colors.diffRemoveSurface,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                              child: Text('- limit = 1;', style: code.copyWith(color: colors.diffRemove)),
                            ),
                          ),
                        ],
                      ),
                    ),
                    gap,
                    block(
                      scheme.surfaceContainer,
                      Text.rich(
                        TextSpan(
                          style: code.copyWith(color: scheme.onSurface),
                          children: [
                            for (final (text, token) in _code)
                              TextSpan(
                                text: text,
                                style: token == null
                                    ? null
                                    : TextStyle(
                                        color: colors[token],
                                        fontStyle: token == ThemeToken.comment ? FontStyle.italic : null,
                                      ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    gap,
                    Wrap(
                      spacing: 4,
                      runSpacing: 4,
                      children: [
                        for (final token in ThemeToken.ansi)
                          DecoratedBox(
                            decoration: BoxDecoration(color: colors[token], borderRadius: BorderRadius.circular(3)),
                            child: const SizedBox(width: 26, height: 14),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A snippet with a run in each syntax token.
const _code = [
  ('// Retry the upload\n', ThemeToken.comment),
  ('export class', ThemeToken.keyword),
  (' ', null),
  ('Uploader', ThemeToken.builtIn),
  (' {\n  ', null),
  ('limit', ThemeToken.number),
  (' = ', null),
  ('3', ThemeToken.number),
  (';\n  ', null),
  ('send', ThemeToken.title),
  ('(name = ', null),
  ('"file"', ThemeToken.string),
  (') {\n    ', null),
  ('return', ThemeToken.keyword),
  (' <', null),
  ('Done', ThemeToken.tag),
  (' ok={', null),
  ('true', ThemeToken.literal),
  ('} />;\n  }\n}', null),
];
