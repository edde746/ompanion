import 'dart:async';

import 'package:flutter/material.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../sessions/sessions_provider.dart';

/// Lets the user pick one of the machine's available models and switches [session] to it (RPC `set_model`,
/// this session only).
Future<void> pickModel(BuildContext context, LiveSession session, Machine machine) async {
  final t = context.t;
  final sessions = context.read<SessionsProvider>();
  final messenger = ScaffoldMessenger.of(context);
  final picked = await showDialog<RpcModel>(
    context: context,
    builder: (_) => _ModelPickerDialog(
      load: ({required bool refresh}) => sessions.models(machine, session.rpc, refresh: refresh),
      current: session.view.config.model,
    ),
  );
  if (picked == null) return;
  try {
    await session.rpc.setModel(picked.provider, picked.id);
  } on Object catch (error) {
    messenger.showSnackBar(SnackBar(content: Text(t.chat.modelFailed(error: '$error'))));
  }
}

class _ModelPickerDialog extends StatefulWidget {
  const _ModelPickerDialog({required this.load, required this.current});

  final Future<List<RpcModel>> Function({required bool refresh}) load;
  final ModelRef? current;

  @override
  State<_ModelPickerDialog> createState() => _ModelPickerDialogState();
}

class _ModelPickerDialogState extends State<_ModelPickerDialog> {
  final _query = TextEditingController();
  late Future<List<RpcModel>> _models = widget.load(refresh: false);

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<RpcModel> _filter(List<RpcModel> models) {
    final words = _query.text.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
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
    return AlertDialog(
      title: Row(
        children: [
          Expanded(child: Text(t.chat.modelTitle)),
          IconButton(
            tooltip: t.chat.refreshModels,
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() => _models = widget.load(refresh: true)),
          ),
        ],
      ),
      content: SizedBox(
        width: 520,
        height: 480,
        child: Column(
          children: [
            TextField(
              controller: _query,
              autofocus: true,
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: t.chat.searchModels),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: FutureBuilder<List<RpcModel>>(
                future: _models,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Center(child: Text(t.chat.modelsFailed(error: '${snapshot.error}')));
                  }
                  final models = snapshot.data;
                  if (models == null) return const Center(child: CircularProgressIndicator());
                  final shown = _filter(models);
                  if (shown.isEmpty) return Center(child: Text(t.chat.noModels));
                  return ListView.builder(
                    itemCount: shown.length,
                    itemBuilder: (context, index) {
                      final model = shown[index];
                      final current = widget.current;
                      final selected = current != null && current.provider == model.provider && current.id == model.id;
                      final newProvider = index == 0 || shown[index - 1].provider != model.provider;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          if (newProvider)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                              child: Text(model.provider, style: theme.textTheme.labelLarge),
                            ),
                          ListTile(
                            dense: true,
                            selected: selected,
                            title: Text(model.name),
                            subtitle: Text(
                              [
                                model.id,
                                if (model.contextWindow != null) t.chat.contextWindow(tokens: model.contextWindow!),
                                if (model.reasoning) t.chat.reasoning,
                              ].join(' · '),
                            ),
                            trailing: selected ? const Icon(Icons.check) : null,
                            onTap: () => Navigator.pop(context, model),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel))],
    );
  }
}
