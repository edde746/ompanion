import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';

import '../../config/accounts.dart';
import '../../i18n/strings.g.dart';

/// Picks a model selector (`provider/id[:thinking]`) from omp's available models, or a typed one. Returns
/// null when dismissed.
Future<String?> pickModel(BuildContext context, {required List<RpcModel> models, required String title, String? current}) =>
    showDialog<String>(
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
  final _search = TextEditingController();
  late String? _thinking = widget.current == null ? null : splitSelector(widget.current!).thinking;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _choose(String model) => Navigator.pop(context, _thinking == null ? model : '$model:$_thinking');

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final words = _search.text.toLowerCase().split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
    final matches = [
      for (final model in widget.models)
        if (words.every('${model.provider}/${model.id} ${model.name}'.toLowerCase().contains)) model,
    ]..sort((a, b) => '${a.provider}/${a.id}'.compareTo('${b.provider}/${b.id}'));
    final typed = _search.text.trim();
    final current = widget.current == null ? null : splitSelector(widget.current!).model;
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 560,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _search,
              autofocus: true,
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search),
                hintText: t.config.roles.searchModels,
                border: const OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                if (matches.length == 1) _choose('${matches.single.provider}/${matches.single.id}');
              },
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(t.config.roles.thinking),
                const SizedBox(width: 12),
                DropdownButton<String?>(
                  value: _thinking,
                  isDense: true,
                  onChanged: (level) => setState(() => _thinking = level),
                  items: [
                    DropdownMenuItem(value: null, child: Text(t.config.roles.thinkingDefault)),
                    for (final level in thinkingLevels) DropdownMenuItem(value: level, child: Text(level)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (typed.contains('/') && !matches.any((model) => '${model.provider}/${model.id}' == typed))
                    ListTile(
                      leading: const Icon(Icons.edit_outlined),
                      title: Text(t.config.roles.useTyped(selector: typed)),
                      subtitle: Text(t.config.roles.useTypedHint),
                      onTap: () => _choose(typed),
                    ),
                  for (final model in matches)
                    ListTile(
                      dense: true,
                      selected: '${model.provider}/${model.id}' == current,
                      leading: Icon(model.reasoning ? Icons.psychology_alt_outlined : Icons.smart_toy_outlined),
                      title: Text(model.name),
                      subtitle: Text(
                        [
                          '${model.provider}/${model.id}',
                          if (model.contextWindow case final window?) t.config.roles.context(tokens: _compact(window)),
                          if (model.input.contains('image')) t.config.roles.vision,
                        ].join(' · '),
                        style: theme.textTheme.bodySmall,
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
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel))],
    );
  }
}

String _compact(int tokens) => tokens >= 1000000
    ? '${(tokens / 1000000).toStringAsFixed(tokens % 1000000 == 0 ? 0 : 1)}M'
    : tokens >= 1000
    ? '${(tokens / 1000).round()}k'
    : '$tokens';
