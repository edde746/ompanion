import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../widgets/activity_mark.dart';
import 'transcript/code_style.dart';

/// Whether `^` tags a model in [text]: not in a `!` or `$` draft, whose body runs as it is, as omp's
/// `allowsModelMentions` (packages/tui/src/prompt/skill-tokens.ts) keeps mentions literal there.
bool allowsModelMentions(String text) {
  final trimmed = text.trimLeft();
  return !trimmed.startsWith('!') && !trimmed.startsWith(r'$');
}

/// The `^` token being typed at the cursor of [value]: where it starts and what follows the `^`, else null. A token
/// starts the text or follows whitespace and runs to the cursor without whitespace, as omp's
/// `MODEL_MENTION_CONTEXT_RE` (packages/tui/src/prompt/model-mention-autocomplete.ts) reads it.
({int start, String query})? mentionQuery(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed || !allowsModelMentions(value.text)) return null;
  final before = value.text.substring(0, selection.baseOffset);
  final token = _mentionToken.firstMatch(before)?.group(1);
  if (token == null) return null;
  return (start: before.length - token.length, query: token.substring(1));
}

final _mentionToken = RegExp(r'(?:^|\s)(\^\S*)$');

/// The selector omp matches a mention against: `formatModelString`, `provider/id`.
String modelSelector(RpcModel model) => '${model.provider}/${model.id}';

/// The name omp shows for a tagged model: `modelMentionDisplayName`, the catalog name without quotes, or the id when
/// the name is empty.
String modelDisplayName(RpcModel model) =>
    (model.name.trim().isEmpty ? model.id : model.name.trim()).replaceAll('"', '');

/// The `^` list above the composer: one dense row per model, its name and selector, up to [_visibleRows] at once with
/// a visible scrollbar when there are more. [models] is null while the list loads; [selected] is highlighted and kept
/// in view; tapping a row picks it.
class ModelMentionPalette extends StatefulWidget {
  const ModelMentionPalette({
    super.key,
    required this.models,
    required this.error,
    required this.selected,
    required this.onPick,
  });

  final List<RpcModel>? models;

  /// Why the list could not load.
  final Object? error;
  final int selected;
  final ValueChanged<RpcModel> onPick;

  @override
  State<ModelMentionPalette> createState() => _ModelMentionPaletteState();
}

const _rowHeight = 36.0;
const _visibleRows = 10;

class _ModelMentionPaletteState extends State<ModelMentionPalette> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(ModelMentionPalette oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selected != widget.selected || !identical(oldWidget.models, widget.models)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls the least distance that shows the selected row.
  void _reveal() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final top = widget.selected * _rowHeight;
    final bottom = top + _rowHeight;
    final target = top < position.pixels
        ? top
        : bottom > position.pixels + position.viewportDimension
        ? bottom - position.viewportDimension
        : null;
    if (target != null) _scroll.jumpTo(target.clamp(0, position.maxScrollExtent));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    final models = widget.models;
    final error = widget.error;
    Widget note(Widget child) => SizedBox(
      height: _rowHeight + 8,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(alignment: AlignmentDirectional.centerStart, child: child),
      ),
    );
    return Material(
      color: theme.colorScheme.surfaceContainer,
      borderRadius: const BorderRadius.all(Radius.circular(AppSizes.cardRadius)),
      clipBehavior: Clip.antiAlias,
      child: error != null
          ? note(
              Text(
                context.t.chat.modelsFailed(error: '$error'),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(color: muted),
              ),
            )
          : models == null
          ? note(const ActivityMark())
          : ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: _rowHeight * _visibleRows + 8),
              child: Scrollbar(
                controller: _scroll,
                thumbVisibility: true,
                child: ListView.builder(
                  controller: _scroll,
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemExtent: _rowHeight,
                  itemCount: models.length,
                  itemBuilder: (context, index) {
                    final model = models[index];
                    return InkWell(
                      onTap: () => widget.onPick(model),
                      child: Container(
                        color: index == widget.selected ? theme.colorScheme.surfaceContainerHighest : null,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        child: Row(
                          children: [
                            Icon(Icons.auto_awesome_outlined, size: 16, color: muted),
                            const SizedBox(width: AppSizes.gap),
                            Flexible(
                              child: Text(
                                modelDisplayName(model),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(width: AppSizes.gap),
                            Expanded(
                              child: Text(
                                modelSelector(model),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: codeTextStyle(theme).copyWith(fontSize: 12, color: muted),
                              ),
                            ),
                            // Room for the scrollbar.
                            const SizedBox(width: 8),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
    );
  }
}
