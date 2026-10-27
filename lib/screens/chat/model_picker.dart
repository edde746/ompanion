import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../sessions/sessions_provider.dart';
import '../../utils/token_count.dart';
import '../../widgets/activity_mark.dart';
import '../../widgets/app_search_field.dart';

/// The composer's model button: opens a searchable list of the machine's models above the composer and switches
/// [session] to the picked one (RPC `set_model`, this session only).
class ModelPicker extends StatefulWidget {
  const ModelPicker({
    super.key,
    required this.session,
    required this.machine,
    required this.model,
    required this.above,
  });

  final LiveSession session;
  final Machine? machine;
  final ModelRef? model;

  /// The composer block the list opens above.
  final GlobalKey above;

  @override
  State<ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<ModelPicker> {
  final _menu = MenuController();

  Future<void> _pick(RpcModel picked) async {
    _menu.close();
    final t = context.t;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.session.rpc.setModel(picked.provider, picked.id);
    } on Object catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(t.chat.modelFailed(error: '$error'))));
    }
  }

  /// The list over the composer block: it starts at the block's start, is at most as wide, and ends [AppSizes.gap]
  /// above it, no taller than the room up to the safe area. RawMenuAnchor builds this in layout whenever the button
  /// moves, so the list follows the composer as the on-screen keyboard raises or lowers it. MenuAnchor builds its
  /// children once, so a list sized at open would lie over the composer and under the keyboard once that rises.
  Widget _overlay(BuildContext context, RawMenuOverlayInfo info, Machine machine) {
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final block = widget.above.currentContext!.findRenderObject()! as RenderBox;
    final rect = MatrixUtils.transformRect(block.getTransformTo(overlay), Offset.zero & block.size);
    // The view's own inset: the composer's MediaQuery has the status bar taken out by the chat's SafeArea.
    final top = MediaQueryData.fromView(View.of(context)).padding.top + AppSizes.gap;
    final width = math.min(_ModelList.maxWidth, rect.width);
    return Positioned(
      left: Directionality.of(context) == TextDirection.rtl ? rect.right - width : rect.left,
      bottom: info.overlaySize.height - rect.top + AppSizes.gap,
      width: width,
      child: TapRegion(
        groupId: info.tapRegionGroupId,
        onTapOutside: (_) => _menu.close(),
        // Esc closes the list before the chat's shortcut, which would abort a run, sees it.
        child: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.escape): _menu.close},
          child: Material(
            color: Theme.of(context).colorScheme.surfaceBright,
            borderRadius: const BorderRadius.all(Radius.circular(AppSizes.radius)),
            clipBehavior: Clip.antiAlias,
            child: _ModelList(
              load: ({required bool refresh}) =>
                  context.read<SessionsProvider>().models(machine, widget.session.rpc, refresh: refresh),
              current: widget.model,
              room: rect.top - AppSizes.gap - top,
              onPick: (picked) => unawaited(_pick(picked)),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final model = widget.model;
    final machine = widget.machine;
    return RawMenuAnchor(
      controller: _menu,
      overlayBuilder: (context, info) => machine == null ? const SizedBox.shrink() : _overlay(context, info, machine),
      builder: (context, controller, _) => ToolbarButton(
        key: const ValueKey('model-picker'),
        icon: Symbols.auto_awesome,
        label: model == null ? t.chat.noModel : (model.name ?? model.id),
        tooltip: model?.selector,
        onPressed: machine == null ? null : () => controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }
}

/// The `alignmentOffset` of a composer toolbar menu opened from [button]: the menu starts at the button and ends
/// [AppSizes.gap] above the composer block [above] instead of covering it. A menu does not fit below the composer, so
/// MenuAnchor flips it up by the offset's `dy`.
Offset menuOffsetAbove(BuildContext button, GlobalKey above) {
  final anchor = button.findRenderObject()! as RenderBox;
  final block = anchor.globalToLocal(
    (above.currentContext!.findRenderObject()! as RenderBox).localToGlobal(Offset.zero),
  );
  return Offset(0, AppSizes.gap - block.dy);
}

/// A low-emphasis toolbar control: icon, label and a chevron, the height of every other control.
class ToolbarButton extends StatelessWidget {
  const ToolbarButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
    this.tooltip,
    this.busy = false,
    this.color,
    this.iconFill = 0,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;

  /// Shows a spinner in place of [icon].
  final bool busy;

  /// Icon and label colour when they carry a state (docs/design.md rule 2); `onSurfaceVariant` otherwise.
  final Color? color;

  /// Fill of [icon]: 1 for a solid glyph (docs/design.md, Icons).
  final double iconFill;

  /// Width with the label shrunk away: the padding, the icon, the gaps and the chevron of [build].
  static const double minWidth = 8 + 16 + 6 + 2 + 16 + 4;

  @override
  Widget build(BuildContext context) {
    final muted = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    final button = TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(foregroundColor: muted, padding: const EdgeInsetsDirectional.only(start: 8, end: 4)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const ActivityMark() else Icon(icon, size: 16, fill: iconFill),
          const SizedBox(width: 6),
          Flexible(
            // As wide as what it shows: a label cut with `…` keeps the chevron right after it.
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textWidthBasis: TextWidthBasis.longestLine,
            ),
          ),
          const SizedBox(width: 2),
          const Icon(Symbols.expand_more, size: 16),
        ],
      ),
    );
    final tooltip = this.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

/// [models] holding every whitespace-separated word of [query] in `provider/id` or their name (case-insensitive),
/// by provider, then name: the model list and the `^` mention list.
List<RpcModel> filterModels(List<RpcModel> models, String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  final matching = [
    for (final model in models)
      if (words.every((word) => '${model.provider}/${model.id} ${model.name}'.toLowerCase().contains(word))) model,
  ];
  matching.sort((a, b) => a.provider != b.provider ? a.provider.compareTo(b.provider) : a.name.compareTo(b.name));
  return matching;
}

class _ModelList extends StatefulWidget {
  const _ModelList({required this.load, required this.current, required this.room, required this.onPick});

  static const double maxWidth = 440;

  final Future<List<RpcModel>> Function({required bool refresh}) load;
  final ModelRef? current;

  /// The height between the safe area's top and the composer block, less the gaps.
  final double room;
  final ValueChanged<RpcModel> onPick;

  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  late Future<List<RpcModel>> _models = widget.load(refresh: false);
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    Widget message(Widget child) => Padding(
      padding: const EdgeInsets.all(24),
      child: Center(heightFactor: 1, child: child),
    );
    // As tall as the models it lists, up to the cap and the room; a longer list scrolls. The search row stays whole.
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: math.min(420, math.max(widget.room, AppSizes.control + 2 * AppSizes.gap))),
      child: Padding(
        padding: const EdgeInsets.all(AppSizes.gap),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  // Inside the popover, tones step up from the popover's own (docs/design.md): onSurface overlays
                  // stand apart from it in both themes, where the field tones of the container ladder would not.
                  child: Theme(
                    data: theme.copyWith(
                      inputDecorationTheme: theme.inputDecorationTheme.copyWith(
                        fillColor: WidgetStateColor.resolveWith(
                          (states) =>
                              scheme.onSurface.withValues(alpha: states.contains(WidgetState.focused) ? 0.08 : 0.06),
                        ),
                      ),
                    ),
                    child: AppSearchField(
                      // On iOS and Android focus would raise the on-screen keyboard over most of the list, which
                      // is there to be tapped; a tap on the field raises it.
                      autofocus: switch (theme.platform) {
                        TargetPlatform.iOS || TargetPlatform.android => false,
                        _ => true,
                      },
                      hint: t.chat.searchModels,
                      onChanged: (query) => setState(() => _query = query),
                    ),
                  ),
                ),
                const SizedBox(width: AppSizes.gap),
                IconButton(
                  tooltip: t.chat.refreshModels,
                  icon: const Icon(Symbols.refresh, size: 18),
                  // The field's height, so the search row is 36 px and the list's 8 px inset holds at the top too.
                  constraints: const BoxConstraints.tightFor(width: AppSizes.control, height: AppSizes.control),
                  onPressed: () => setState(() => _models = widget.load(refresh: true)),
                ),
              ],
            ),
            Flexible(
              child: FutureBuilder<List<RpcModel>>(
                future: _models,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return message(Text(t.chat.modelsFailed(error: '${snapshot.error}')));
                  }
                  final models = snapshot.data;
                  if (models == null) return message(const ActivityMark(size: 20));
                  final shown = filterModels(models, _query);
                  if (shown.isEmpty) return message(Text(t.chat.noModels));
                  final current = widget.current;
                  bool isCurrent(RpcModel model) =>
                      current != null && current.provider == model.provider && current.id == model.id;
                  // A column rather than a lazy list: the menu measures its content, which a viewport cannot report.
                  return SingleChildScrollView(
                    // Not the route's PrimaryScrollController, which a scroll view takes by default on iOS and Android.
                    primary: false,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (index, model) in shown.indexed) ...[
                          if (index == 0 || shown[index - 1].provider != model.provider)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                              child: Text(
                                model.provider,
                                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ListTile(
                            dense: true,
                            minTileHeight: 0,
                            minVerticalPadding: 4,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.all(Radius.circular(AppSizes.radius)),
                            ),
                            selectedTileColor: scheme.onSurface.withValues(alpha: 0.10),
                            selected: isCurrent(model),
                            title: Text(model.name),
                            subtitle: Text(
                              [
                                model.id,
                                if (model.contextWindow case final window?)
                                  t.chat.contextWindow(tokens: formatTokens(window)),
                                if (model.reasoning) t.chat.reasoning,
                              ].join(' · '),
                            ),
                            trailing: isCurrent(model) ? const Icon(Symbols.check, size: 18) : null,
                            onTap: () => widget.onPick(model),
                          ),
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
