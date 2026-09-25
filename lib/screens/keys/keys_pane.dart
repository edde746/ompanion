import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/keys_provider.dart';
import '../../providers/machines_provider.dart';
import 'key_dialogs.dart';

/// SSH keys of this device: import, generate, copy the public half, delete.
class KeysPane extends StatelessWidget {
  const KeysPane({super.key});

  Future<void> _delete(BuildContext context, SshKeyRow key) async {
    final t = context.t;
    final users = [
      for (final machine in context.read<MachinesProvider>().machines)
        if (machine is SshMachine && machine.hops.any((hop) => hop.keyId == key.id)) machine.name,
    ];
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(t.keys.deleteTitle(name: key.name)),
        content: Text(
          [t.keys.deleteBody, if (users.isNotEmpty) t.keys.deleteUsedBy(machines: users.join(', '))].join('\n\n'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.common.delete)),
        ],
      ),
    );
    if (confirmed == true && context.mounted) await context.read<KeysProvider>().delete(key);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final keys = context.watch<KeysProvider>().keys;
    final mono = theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace');
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.file_download_outlined),
              label: Text(t.keys.import),
              onPressed: () => showImportKeyDialog(context),
            ),
            FilledButton.tonalIcon(
              icon: const Icon(Icons.auto_awesome_outlined),
              label: Text(t.keys.generate),
              onPressed: () => showGenerateKeyDialog(context),
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (keys.isEmpty) Text(t.keys.empty),
        for (final key in keys)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              leading: const Icon(Icons.key_outlined),
              title: Text(key.name),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(key.type),
                  SelectableText(key.fingerprint, style: mono),
                ],
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: t.keys.copyPublicKey,
                    icon: const Icon(Icons.copy),
                    onPressed: () => copyPublicKey(context, key),
                  ),
                  IconButton(
                    tooltip: t.common.delete,
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _delete(context, key),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
