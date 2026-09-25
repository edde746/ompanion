import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:omp_core/ssh.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';

import '../../app/build_channel.dart';
import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../providers/keys_provider.dart';

/// OpenSSH private keys are a few KiB; anything much larger is the wrong file.
const _maxKeyFileBytes = 64 * 1024;

/// Imports a pasted or picked private key. Pops the stored key, or null when cancelled.
Future<SshKeyRow?> showImportKeyDialog(BuildContext context) =>
    showDialog<SshKeyRow>(context: context, builder: (_) => const _ImportKeyDialog());

/// Generates an Ed25519 key and shows its public half. Pops the stored key, or null when cancelled.
Future<SshKeyRow?> showGenerateKeyDialog(BuildContext context) =>
    showDialog<SshKeyRow>(context: context, builder: (_) => const _GenerateKeyDialog());

Future<void> copyPublicKey(BuildContext context, SshKeyRow key) async {
  await Clipboard.setData(ClipboardData(text: key.publicKey));
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.t.keys.publicKeyCopied)));
}

String describeKeyError(Translations t, Exception error) => switch (error) {
  SshKeyException(:final problem) => switch (problem) {
    SshKeyProblem.malformed => t.keys.malformed,
    SshKeyProblem.unsupported => t.keys.unsupported,
    SshKeyProblem.passphraseRequired => t.keys.passphraseRequired,
    SshKeyProblem.wrongPassphrase => t.keys.wrongPassphrase,
  },
  DuplicateSshKey(:final existing) => t.keys.duplicate(name: existing.name),
  _ => '$error',
};

class _ImportKeyDialog extends StatefulWidget {
  const _ImportKeyDialog();

  @override
  State<_ImportKeyDialog> createState() => _ImportKeyDialogState();
}

class _ImportKeyDialogState extends State<_ImportKeyDialog> {
  final _form = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _pem = TextEditingController();
  final _passphrase = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _pem.dispose();
    _passphrase.dispose();
    super.dispose();
  }

  Future<void> _chooseFile() async {
    final t = context.t;
    final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'];
    final file = await FilePicker.pickFile(
      dialogTitle: t.keys.importTitle,
      initialDirectory: hostAccessAvailable && home != null ? p.join(home, '.ssh') : null,
    );
    if (file == null || !mounted) return;
    final length = await file.length();
    if (length == null || length > _maxKeyFileBytes) {
      setState(() => _error = t.keys.fileTooLarge);
      return;
    }
    final String text;
    try {
      text = utf8.decode(await file.readAsBytes());
    } on FormatException {
      setState(() => _error = t.keys.malformed);
      return;
    }
    if (!mounted) return;
    setState(() {
      _error = null;
      _pem.text = text;
      if (_name.text.trim().isEmpty) _name.text = file.name;
    });
  }

  Future<void> _import() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final t = context.t;
    try {
      final key = await context.read<KeysProvider>().importKey(
        name: _name.text.trim(),
        pem: _pem.text,
        passphrase: _passphrase.text.isEmpty ? null : _passphrase.text,
      );
      if (mounted) Navigator.pop(context, key);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = describeKeyError(t, error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.keys.importTitle),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: InputDecoration(labelText: t.keys.name),
                  validator: (value) => value == null || value.trim().isEmpty ? t.common.required : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _pem,
                  minLines: 4,
                  maxLines: 8,
                  autocorrect: false,
                  enableSuggestions: false,
                  style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    labelText: t.keys.privateKey,
                    hintText: t.keys.privateKeyHint,
                    alignLabelWithHint: true,
                  ),
                  validator: (value) => value == null || value.trim().isEmpty ? t.common.required : null,
                ),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    icon: const Icon(Icons.folder_open_outlined),
                    label: Text(t.common.chooseFile),
                    onPressed: _busy ? null : _chooseFile,
                  ),
                ),
                TextFormField(
                  controller: _passphrase,
                  obscureText: true,
                  decoration: InputDecoration(labelText: t.keys.passphrase, helperText: t.keys.passphraseHint),
                  onFieldSubmitted: (_) => _import(),
                ),
                if (_error case final error?) ...[
                  const SizedBox(height: 12),
                  Text(error, style: TextStyle(color: theme.colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: _busy ? null : _import, child: Text(t.keys.importAction)),
      ],
    );
  }
}

class _GenerateKeyDialog extends StatefulWidget {
  const _GenerateKeyDialog();

  @override
  State<_GenerateKeyDialog> createState() => _GenerateKeyDialogState();
}

class _GenerateKeyDialogState extends State<_GenerateKeyDialog> {
  final _form = GlobalKey<FormState>();

  /// The device name as the default, so an `authorized_keys` line tells which device holds the key.
  final _name = TextEditingController(text: Platform.localHostname);
  SshKeyRow? _generated;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _generate() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _busy = true);
    try {
      final key = await context.read<KeysProvider>().generateEd25519(name: _name.text.trim());
      if (mounted) setState(() => _generated = key);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = '$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final generated = _generated;
    if (generated != null) {
      return AlertDialog(
        title: Text(generated.name),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.keys.generatedBody),
              const SizedBox(height: 12),
              SelectableText(
                generated.publicKey,
                style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: Text(t.keys.copyPublicKey),
            onPressed: () => copyPublicKey(context, generated),
          ),
          FilledButton(onPressed: () => Navigator.pop(context, generated), child: Text(t.common.close)),
        ],
      );
    }
    return AlertDialog(
      title: Text(t.keys.generateTitle),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _name,
                autofocus: true,
                decoration: InputDecoration(labelText: t.keys.name),
                validator: (value) => value == null || value.trim().isEmpty ? t.common.required : null,
                onFieldSubmitted: (_) => _generate(),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 12),
                Text(error, style: TextStyle(color: theme.colorScheme.error)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: _busy ? null : _generate, child: Text(t.keys.generateAction)),
      ],
    );
  }
}
