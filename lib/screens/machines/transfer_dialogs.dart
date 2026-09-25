import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../providers/machines_provider.dart';

/// Exports stay small: machine records and host keys only.
const _maxImportBytes = 1024 * 1024;

/// Shows the export of every SSH machine, to copy or save. Secrets are never part of it.
Future<void> showExportMachinesDialog(BuildContext context) async {
  final provider = context.read<MachinesProvider>();
  final machines = provider.machines.whereType<SshMachine>().toList();
  final json = await provider.exportJson(machines);
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _ExportDialog(json: json, count: machines.length),
  );
}

Future<void> showImportMachinesDialog(BuildContext context) =>
    showDialog<void>(context: context, builder: (_) => const _ImportDialog());

class _ExportDialog extends StatefulWidget {
  const _ExportDialog({required this.json, required this.count});

  final String json;
  final int count;

  @override
  State<_ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<_ExportDialog> {
  String? _status;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.json));
    if (mounted) setState(() => _status = context.t.common.copied);
  }

  Future<void> _save() async {
    final t = context.t;
    final saved = await FilePicker.saveFile(
      dialogTitle: t.transfer.exportTitle,
      fileName: 'omp-app-machines.json',
      bytes: utf8.encode(widget.json),
      mimeType: 'application/json',
    );
    if (saved != null && mounted) setState(() => _status = t.transfer.saved);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final empty = widget.count == 0;
    return AlertDialog(
      title: Text(t.transfer.exportTitle),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(empty ? t.transfer.exportNone : t.transfer.exportBody(count: widget.count)),
            if (_status case final status?) ...[const SizedBox(height: 12), Text(status)],
          ],
        ),
      ),
      actions: [
        if (!empty) ...[
          TextButton.icon(icon: const Icon(Icons.copy), label: Text(t.common.copy), onPressed: _copy),
          TextButton.icon(icon: const Icon(Icons.save_alt), label: Text(t.transfer.saveFile), onPressed: _save),
        ],
        FilledButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close)),
      ],
    );
  }
}

class _ImportDialog extends StatefulWidget {
  const _ImportDialog();

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _text = TextEditingController();
  String? _status;
  bool _failed = false;
  bool _busy = false;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _chooseFile() async {
    final t = context.t;
    final file = await FilePicker.pickFile(
      dialogTitle: t.transfer.importTitle,
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (file == null || !mounted) return;
    final length = await file.length();
    if (length == null || length > _maxImportBytes) {
      setState(() {
        _failed = true;
        _status = t.transfer.invalid(error: t.keys.fileTooLarge);
      });
      return;
    }
    final bytes = await file.readAsBytes();
    if (mounted) setState(() => _text.text = utf8.decode(bytes, allowMalformed: true));
  }

  Future<void> _import() async {
    final t = context.t;
    setState(() => _busy = true);
    try {
      final result = await context.read<MachinesProvider>().importJson(_text.text);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = false;
        _status = t.transfer.imported(added: result.added, skipped: result.skipped);
      });
    } on FormatException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
        _status = t.transfer.invalid(error: error.message);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(t.transfer.importTitle),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(t.transfer.importHint),
            const SizedBox(height: 12),
            TextField(
              controller: _text,
              minLines: 6,
              maxLines: 12,
              style: theme.textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: TextButton.icon(
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(t.common.chooseFile),
                onPressed: _busy ? null : _chooseFile,
              ),
            ),
            if (_status case final status?)
              Text(status, style: _failed ? TextStyle(color: theme.colorScheme.error) : null),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.close)),
        FilledButton(onPressed: _busy ? null : _import, child: Text(t.transfer.importAction)),
      ],
    );
  }
}
