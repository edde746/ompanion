import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../sessions/sessions_provider.dart';
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
  Offset _offset = Offset.zero;
  double _width = _ModelList.maxWidth;

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

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final model = widget.model;
    final machine = widget.machine;
    return MenuAnchor(
      controller: _menu,
      alignmentOffset: _offset,
      menuChildren: [
        if (machine != null)
          _ModelList(
            load: ({required bool refresh}) =>
                context.read<SessionsProvider>().models(machine, widget.session.rpc, refresh: refresh),
            current: model,
            width: _width,
            onPick: (picked) => unawaited(_pick(picked)),
          ),
      ],
      builder: (context, controller, _) => ToolbarButton(
        key: const ValueKey('model-picker'),
        icon: Icons.auto_awesome_outlined,
        label: model == null ? t.chat.noModel : (model.name ?? model.id),
        tooltip: model?.selector,
        onPressed: machine == null
            ? null
            : () {
                if (controller.isOpen) return controller.close();
                // The wide list starts where the composer does and is at most as wide.
                setState(() {
                  _offset = menuOffsetAbove(this.context, widget.above, alignStart: true);
                  _width = math.min(_ModelList.maxWidth, widget.above.currentContext!.size!.width);
                });
                controller.open();
              },
      ),
    );
  }
}

/// The `alignmentOffset` of a composer toolbar menu opened from [button]: the menu ends [AppSizes.gap] above the
/// composer block [above] instead of covering it, and starts at the block's start with [alignStart], else at the
/// button's. A menu does not fit below the composer, so MenuAnchor flips it up by the offset's `dy`.
Offset menuOffsetAbove(BuildContext button, GlobalKey above, {required bool alignStart}) {
  final anchor = button.findRenderObject()! as RenderBox;
  final block = anchor.globalToLocal((above.currentContext!.findRenderObject()! as RenderBox).localToGlobal(Offset.zero));
  return Offset(alignStart ? block.dx : 0, AppSizes.gap - block.dy);
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
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onPressed;

  /// Shows a spinner in place of [icon].
  final bool busy;

  /// Width with the label shrunk away: the padding, the icon, the gaps and the chevron of [build].
  static const double minWidth = 8 + 16 + 6 + 2 + 16 + 4;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    final button = TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: muted,
        padding: const EdgeInsetsDirectional.only(start: 8, end: 4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2))
          else
            Icon(icon, size: 16),
          const SizedBox(width: 6),
          Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 2),
          const Icon(Icons.expand_more, size: 16),
        ],
      ),
    );
    final tooltip = this.tooltip;
    return tooltip == null ? button : Tooltip(message: tooltip, child: button);
  }
}

class _ModelList extends StatefulWidget {
  const _ModelList({required this.load, required this.current, required this.width, required this.onPick});

  static const double maxWidth = 440;

  final Future<List<RpcModel>> Function({required bool refresh}) load;
  final ModelRef? current;
  final double width;
  final ValueChanged<RpcModel> onPick;

  @override
  State<_ModelList> createState() => _ModelListState();
}

class _ModelListState extends State<_ModelList> {
  late Future<List<RpcModel>> _models = widget.load(refresh: false);
  String _query = '';

  List<RpcModel> _filter(List<RpcModel> models) {
    final words = _query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    final matching = [
      for (final model in models)
        if (words.every((word) => '${model.provider}/${model.id} ${model.name}'.toLowerCase().contains(word))) model,
    ];
    matching.sort((a, b) => a.provider != b.provider ? a.provider.compareTo(b.provider) : a.name.compareTo(b.name));
    return matching;
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final screen = MediaQuery.sizeOf(context);
    Widget message(Widget child) =>
        Padding(padding: const EdgeInsets.all(24), child: Center(heightFactor: 1, child: child));
    final width = widget.width;
    // As tall as the models it lists, up to the cap; a longer list scrolls.
    return ConstrainedBox(
      constraints: BoxConstraints(minWidth: width, maxWidth: width, maxHeight: math.min(420, screen.height * 0.6)),
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
                          (states) => scheme.onSurface.withValues(alpha: states.contains(WidgetState.focused) ? 0.08 : 0.06),
                        ),
                      ),
                    ),
                    child: AppSearchField(
                      autofocus: true,
                      hint: t.chat.searchModels,
                      onChanged: (query) => setState(() => _query = query),
                    ),
                  ),
                ),
                const SizedBox(width: AppSizes.gap),
                IconButton(
                  tooltip: t.chat.refreshModels,
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: () => setState(() => _models = widget.load(refresh: true)),
                ),
              ],
            ),
            const SizedBox(height: AppSizes.gap),
            Flexible(
              child: FutureBuilder<List<RpcModel>>(
                future: _models,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return message(Text(t.chat.modelsFailed(error: '${snapshot.error}')));
                  }
                  final models = snapshot.data;
                  if (models == null) return message(const CircularProgressIndicator());
                  final shown = _filter(models);
                  if (shown.isEmpty) return message(Text(t.chat.noModels));
                  final current = widget.current;
                  bool isCurrent(RpcModel model) =>
                      current != null && current.provider == model.provider && current.id == model.id;
                  // A column rather than a lazy list: the menu measures its content, which a viewport cannot report.
                  return SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final (index, model) in shown.indexed) ...[
                          if (index == 0 || shown[index - 1].provider != model.provider)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                              child: Text(
                                model.provider,
                                style: theme.textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
                              ),
                            ),
                          ListTile(
                            dense: true,
                            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                            shape: const RoundedRectangleBorder(
                              borderRadius: BorderRadius.all(Radius.circular(AppSizes.radius)),
                            ),
                            selectedTileColor: scheme.onSurface.withValues(alpha: 0.14),
                            selected: isCurrent(model),
                            title: Text(model.name),
                            subtitle: Text(
                              [
                                model.id,
                                if (model.contextWindow != null) t.chat.contextWindow(tokens: model.contextWindow!),
                                if (model.reasoning) t.chat.reasoning,
                              ].join(' · '),
                            ),
                            trailing: isCurrent(model) ? const Icon(Icons.check, size: 18) : null,
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
