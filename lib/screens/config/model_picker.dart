import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:omp_core/rpc.dart';

import '../../app/theme.dart';
import '../../config/accounts.dart';
import '../../i18n/strings.g.dart';
import '../../utils/token_count.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/app_select.dart';

/// Picks a model selector (`provider/id[:thinking]`) from omp's available models, or a typed one. Returns
/// null when dismissed.
Future<String?> pickModel(
  BuildContext context, {
  required List<RpcModel> models,
  required String title,
  String? current,
}) => showDialog<String>(
  context: context,
  builder: (context) => _ModelPicker(models: models, title: title, current: current),
);

class _ModelPicker extends StatefulWidget {
  const _ModelPicker({required this.models, required this.title, this.current});

  final List<RpcModel> models;
  final String title;
  final String? current;

  @override
  State<_ModelPicker> createState() => _ModelPickerState();
}

class _ModelPickerState extends State<_ModelPicker> {
  String _query = '';
  late String? _thinking = widget.current == null ? null : splitSelector(widget.current!).thinking;

  void _choose(String model) => Navigator.pop(context, _thinking == null ? model : '$model:$_thinking');

  List<RpcModel> _matches(String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    return [
      for (final model in widget.models)
        if (words.every('${model.provider}/${model.id} ${model.name}'.toLowerCase().contains)) model,
    ]..sort((a, b) => '${a.provider}/${a.id}'.compareTo('${b.provider}/${b.id}'));
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final matches = _matches(_query);
    final typed = _query.trim();
    final current = widget.current == null ? null : splitSelector(widget.current!).model;
    return AlertDialog(
      title: Text(widget.title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 520),
        child: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: AppSearchField(
                      autofocus: true,
                      hint: t.config.roles.searchModels,
                      onChanged: (text) => setState(() => _query = text),
                      onSubmitted: (text) {
                        final found = _matches(text);
                        if (found.length == 1) _choose('${found.single.provider}/${found.single.id}');
                      },
                    ),
                  ),
                  const SizedBox(width: AppSizes.gap),
                  AppSelect<String?>(
                    value: _thinking,
                    tooltip: t.config.roles.thinking,
                    options: [
                      (null, t.config.roles.thinkingDefault),
                      for (final level in thinkingLevels) (level, level),
                    ],
                    onChanged: (level) => setState(() => _thinking = level),
                  ),
                ],
              ),
              const SizedBox(height: AppSizes.gap),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    if (typed.contains('/') && !matches.any((model) => '${model.provider}/${model.id}' == typed))
                      ListTile(
                        dense: true,
                        leading: const Icon(Symbols.edit),
                        title: Text(t.config.roles.useTyped(selector: typed)),
                        subtitle: Text(t.config.roles.useTypedHint),
                        onTap: () => _choose(typed),
                      ),
                    for (final model in matches)
                      ListTile(
                        dense: true,
                        selected: '${model.provider}/${model.id}' == current,
                        leading: Icon(model.reasoning ? Symbols.psychology_alt : Symbols.smart_toy, size: 20),
                        title: Text(model.name),
                        subtitle: Text(
                          [
                            '${model.provider}/${model.id}',
                            if (model.contextWindow case final window?)
                              t.config.roles.context(tokens: formatTokens(window)),
                            if (model.input.contains('image')) t.config.roles.vision,
                          ].join(' · '),
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        ),
                        onTap: () => _choose('${model.provider}/${model.id}'),
                      ),
                    if (matches.isEmpty && !typed.contains('/'))
                      Padding(padding: const EdgeInsets.all(16), child: Text(t.config.roles.noModels)),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel))],
    );
  }
}
