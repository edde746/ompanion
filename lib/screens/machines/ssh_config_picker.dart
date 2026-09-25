import 'package:flutter/material.dart';
import 'package:omp_core/ssh.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/machine_draft.dart';
import '../../providers/keys_provider.dart';
import '../../services/ssh_config_import.dart';

/// Lists the `Host` aliases of `~/.ssh/config`; pops a draft resolved with `ssh -G` for the chosen one.
Future<MachineDraft?> showSshConfigPicker(BuildContext context) =>
    showDialog<MachineDraft>(context: context, builder: (_) => const _SshConfigPicker());

class _SshConfigPicker extends StatefulWidget {
  const _SshConfigPicker();

  @override
  State<_SshConfigPicker> createState() => _SshConfigPickerState();
}

class _SshConfigPickerState extends State<_SshConfigPicker> {
  final _aliases = listSshConfigAliases();
  String? _resolving;
  String? _error;

  Future<void> _pick(String alias) async {
    setState(() {
      _resolving = alias;
      _error = null;
    });
    try {
      final draft = await draftFromSshAlias(alias, keys: context.read<KeysProvider>().keys);
      if (mounted) Navigator.pop(context, draft);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _resolving = null;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(t.sshConfig.title),
      content: SizedBox(
        width: 420,
        child: FutureBuilder<List<String>>(
          future: _aliases,
          builder: (context, snapshot) {
            if (snapshot.hasError) return Text(t.sshConfig.failed(error: '${snapshot.error}'));
            final aliases = snapshot.data;
            if (aliases == null) return const Center(heightFactor: 3, child: CircularProgressIndicator());
            if (aliases.isEmpty) return Text(t.sshConfig.empty);
            return Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_error case final error?)
                  Text(error, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final alias in aliases)
                        ListTile(
                          leading: const Icon(Icons.dns_outlined),
                          title: Text(alias),
                          trailing: _resolving == alias
                              ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                              : null,
                          onTap: _resolving == null ? () => _pick(alias) : null,
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
      actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close))],
    );
  }
}
