import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../app/build_channel.dart';
import '../../app/theme.dart';
import '../../database/app_database.dart';
import '../../i18n/strings.g.dart';
import '../../models/machine.dart';
import '../../models/machine_draft.dart';
import '../../providers/keys_provider.dart';
import '../../providers/machines_provider.dart';
import '../../providers/shell_provider.dart';
import '../../services/secret_store.dart';
import '../../utils/ids.dart';
import '../../widgets/app_segmented.dart';
import '../../widgets/app_select.dart';
import '../../widgets/labeled_field.dart';
import '../keys/key_dialogs.dart';
import '../shell/layout.dart';
import 'ssh_config_picker.dart';
import 'tailscale_picker.dart';

/// Adds a machine, or edits [machine]. A new machine is selected after saving.
Future<void> showMachineEditor(BuildContext context, {Machine? machine}) async {
  // A new hop's default auth depends on whether keys are stored.
  await context.read<KeysProvider>().ready;
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (context) => isCompact(context)
        ? Dialog.fullscreen(child: MachineEditor(machine: machine))
        : Dialog(
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 640, maxHeight: 800),
              child: MachineEditor(machine: machine),
            ),
          ),
  );
}

/// Form fields of one hop. The id owns the hop's saved password.
class _HopFields {
  _HopFields._({
    required this.id,
    required String host,
    required int port,
    required String user,
    required this.auth,
    required this.keyId,
  }) : host = TextEditingController(text: host),
       port = TextEditingController(text: '$port'),
       user = TextEditingController(text: user);

  _HopFields.blank(String id, AuthMethod auth) : this._(id: id, host: '', port: 22, user: '', auth: auth, keyId: null);

  _HopFields.from(SshEndpoint hop)
    : this._(id: hop.id, host: hop.host, port: hop.port, user: hop.user, auth: hop.auth, keyId: hop.keyId);

  _HopFields.draft(String id, EndpointDraft draft)
    : this._(id: id, host: draft.host, port: draft.port, user: draft.user, auth: draft.auth, keyId: draft.keyId);

  final String id;
  final TextEditingController host;
  final TextEditingController port;
  final TextEditingController user;
  final password = TextEditingController();
  AuthMethod auth;
  String? keyId;
  bool savePassword = true;
  bool hasSavedPassword = false;

  SshEndpoint toEndpoint() => SshEndpoint(
    id: id,
    host: host.text.trim(),
    port: int.parse(port.text.trim()),
    user: user.text.trim(),
    auth: auth,
    keyId: auth == AuthMethod.key ? keyId : null,
  );

  void dispose() {
    host.dispose();
    port.dispose();
    user.dispose();
    password.dispose();
  }
}

class MachineEditor extends StatefulWidget {
  const MachineEditor({super.key, this.machine});

  final Machine? machine;

  @override
  State<MachineEditor> createState() => _MachineEditorState();
}

class _MachineEditorState extends State<MachineEditor> {
  final _form = GlobalKey<FormState>();
  late final String _id;
  late MachineKind _kind;
  late final TextEditingController _name;
  late final _HopFields _target;
  final List<_HopFields> _jumps = [];
  String? _sshConfigAlias;
  bool _tailscale = false;
  List<KnownHostRow> _hostKeys = const [];
  String? _ignoredProxyCommand;
  bool _saving = false;

  bool get _editing => widget.machine != null;

  @override
  void initState() {
    super.initState();
    final machine = widget.machine;
    _id = machine?.id ?? newId();
    _name = TextEditingController(text: machine?.name ?? '');
    switch (machine) {
      case SshMachine():
        _kind = MachineKind.ssh;
        _target = _HopFields.from(machine.target);
        _jumps.addAll(machine.jumps.map(_HopFields.from));
        _sshConfigAlias = machine.sshConfigAlias;
        _tailscale = machine.tailscale;
      case LocalMachine():
        _kind = MachineKind.local;
        _target = _HopFields.blank(_id, _defaultAuth());
      case null:
        _kind = thisComputerAvailable && !context.read<MachinesProvider>().hasLocal
            ? MachineKind.local
            : MachineKind.ssh;
        _target = _HopFields.blank(_id, _defaultAuth());
    }
    _loadSavedPasswords();
  }

  AuthMethod _defaultAuth() {
    if (context.read<KeysProvider>().keys.isNotEmpty) return AuthMethod.key;
    return isDesktop ? AuthMethod.agent : AuthMethod.password;
  }

  Future<void> _loadSavedPasswords() async {
    final secrets = context.read<SecretStore>();
    for (final hop in [_target, ..._jumps]) {
      if (hop.auth == AuthMethod.password) hop.hasSavedPassword = await secrets.password(hop.id) != null;
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.dispose();
    _target.dispose();
    for (final jump in _jumps) {
      jump.dispose();
    }
    super.dispose();
  }

  /// Controllers of removed hops stay attached to their fields until the next frame is built.
  void _disposeLater(Iterable<_HopFields> hops) {
    final removed = hops.toList();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final hop in removed) {
        hop.dispose();
      }
    });
  }

  void _applyDraft(MachineDraft draft) {
    setState(() {
      _kind = MachineKind.ssh;
      _name.text = draft.name;
      final target = draft.target;
      _target
        ..host.text = target.host
        ..port.text = '${target.port}'
        ..user.text = target.user
        ..auth = target.auth
        ..keyId = target.keyId;
      _disposeLater(_jumps);
      _jumps
        ..clear()
        ..addAll([for (final jump in draft.jumps) _HopFields.draft(newId(), jump)]);
      _sshConfigAlias = draft.sshConfigAlias;
      _tailscale = draft.tailscale;
      _hostKeys = draft.hostKeys;
      _ignoredProxyCommand = draft.ignoredProxyCommand;
    });
  }

  Future<void> _fromSshConfig() async {
    final draft = await showSshConfigPicker(context);
    if (draft != null && mounted) _applyDraft(draft);
  }

  Future<void> _fromTailscale() async {
    final draft = await showTailscalePicker(context);
    if (draft != null && mounted) _applyDraft(draft);
  }

  Future<void> _save() async {
    final invalid = _form.currentState!.validateGranularly();
    if (invalid.isNotEmpty) {
      // It may be a hop below the visible part of the form.
      await Scrollable.ensureVisible(
        invalid.first.context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 200),
      );
      return;
    }
    setState(() => _saving = true);
    final machines = context.read<MachinesProvider>();
    final shell = context.read<ShellProvider>();
    try {
      final now = DateTime.now();
      final createdAt = widget.machine?.createdAt ?? now;
      final name = _name.text.trim();
      final Machine machine;
      final passwords = <String, String?>{};
      var hostKeys = const <KnownHostRow>[];
      switch (_kind) {
        case MachineKind.local:
          machine = LocalMachine(id: _id, name: name, createdAt: createdAt, updatedAt: now);
        case MachineKind.ssh:
          final target = _target.toEndpoint();
          machine = SshMachine(
            id: _id,
            name: name,
            createdAt: createdAt,
            updatedAt: now,
            target: target,
            jumps: [for (final jump in _jumps) jump.toEndpoint()],
            sshConfigAlias: _sshConfigAlias,
            tailscale: _tailscale,
          );
          for (final hop in [_target, ..._jumps]) {
            if (hop.auth != AuthMethod.password) continue;
            if (!hop.savePassword) {
              passwords[hop.id] = null;
            } else if (hop.password.text.isNotEmpty) {
              passwords[hop.id] = hop.password.text;
            }
          }
          // Keys from Tailscale belong to the host they were listed for; an edited host does not inherit them.
          hostKeys = [
            for (final row in _hostKeys)
              if (row.host == target.host && row.port == target.port) row,
          ];
      }
      await machines.save(machine, passwords: passwords, hostKeys: hostKeys);
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
      return;
    }
    if (!_editing) shell.select(MachineSelection(_id));
    if (mounted) Navigator.pop(context);
  }

  Future<void> _addKey(_HopFields hop, {required bool generate}) async {
    final key = generate ? await showGenerateKeyDialog(context) : await showImportKeyDialog(context);
    if (key != null && mounted) setState(() => hop.keyId = key.id);
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final canChooseKind = !_editing && thisComputerAvailable && !context.watch<MachinesProvider>().hasLocal;
    return Form(
      key: _form,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 20, 16, 12),
            child: Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Text(_editing ? t.editor.editTitle : t.editor.addTitle, style: theme.textTheme.headlineSmall),
                if (_kind == MachineKind.ssh && hostAccessAvailable)
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton.icon(
                        icon: const Icon(Symbols.description),
                        label: Text(t.editor.fromSshConfig),
                        onPressed: _fromSshConfig,
                      ),
                      TextButton.icon(
                        icon: const Icon(Symbols.lan),
                        label: Text(t.editor.fromTailscale),
                        onPressed: _fromTailscale,
                      ),
                    ],
                  ),
              ],
            ),
          ),
          Expanded(
            // Not a ListView: validate() checks only mounted fields, and a lazy list unmounts the hops scrolled
            // out of view.
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (canChooseKind) ...[
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: AppSegmented<MachineKind>(
                        value: _kind,
                        segments: [
                          (MachineKind.local, t.machines.thisComputer, Symbols.computer),
                          (MachineKind.ssh, t.editor.kindSsh, Symbols.dns),
                        ],
                        onChanged: (kind) => setState(() => _kind = kind),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                  LabeledField(
                    label: t.editor.name,
                    child: TextFormField(
                      controller: _name,
                      autofocus: !isCompact(context),
                      validator: (value) => _required(t, value),
                    ),
                  ),
                  if (_kind == MachineKind.ssh) ...[
                    const SizedBox(height: 16),
                    _HopEditor(
                      hop: _target,
                      onChanged: () => setState(() {}),
                      onAddKey: (generate) => _addKey(_target, generate: generate),
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(t.editor.tailscale),
                      value: _tailscale,
                      onChanged: (value) => setState(() => _tailscale = value),
                    ),
                    if (_ignoredProxyCommand case final command?)
                      _Note(
                        icon: Symbols.warning,
                        text: t.editor.proxyCommandIgnored(command: command),
                      ),
                    if (_hostKeys.isNotEmpty) _Note(icon: Symbols.verified_user, text: t.editor.hostKeysPretrusted),
                    const SizedBox(height: 16),
                    Text(t.editor.jumpHosts, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(t.editor.jumpHostsHelp, style: theme.textTheme.bodySmall),
                    for (final (index, jump) in _jumps.indexed)
                      Card(
                        key: ObjectKey(jump),
                        // One tone below the dialog, so its fields and buttons keep their own tone.
                        color: theme.colorScheme.surfaceContainerLow,
                        margin: const EdgeInsets.only(top: 12),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(t.editor.jumpHostN(n: index + 1), style: theme.textTheme.titleSmall),
                                  ),
                                  IconButton(
                                    tooltip: t.editor.moveUp,
                                    icon: const Icon(Symbols.arrow_upward),
                                    onPressed: index == 0
                                        ? null
                                        : () => setState(() => _jumps.insert(index - 1, _jumps.removeAt(index))),
                                  ),
                                  IconButton(
                                    tooltip: t.editor.moveDown,
                                    icon: const Icon(Symbols.arrow_downward),
                                    onPressed: index == _jumps.length - 1
                                        ? null
                                        : () => setState(() => _jumps.insert(index + 1, _jumps.removeAt(index))),
                                  ),
                                  IconButton(
                                    tooltip: t.editor.remove,
                                    icon: const Icon(Symbols.close),
                                    onPressed: () => setState(() => _disposeLater([_jumps.removeAt(index)])),
                                  ),
                                ],
                              ),
                              Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: _HopEditor(
                                  hop: jump,
                                  onChanged: () => setState(() {}),
                                  onAddKey: (generate) => _addKey(jump, generate: generate),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: TextButton.icon(
                        icon: const Icon(Symbols.add),
                        label: Text(t.editor.addJumpHost),
                        onPressed: () => setState(() => _jumps.add(_HopFields.blank(newId(), _defaultAuth()))),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
                const SizedBox(width: 8),
                FilledButton(onPressed: _saving ? null : _save, child: Text(t.common.save)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

String? _required(Translations t, String? value) => value == null || value.trim().isEmpty ? t.common.required : null;

class _HopEditor extends StatelessWidget {
  const _HopEditor({required this.hop, required this.onChanged, required this.onAddKey});

  final _HopFields hop;
  final VoidCallback onChanged;

  /// Imports (false) or generates (true) a key and selects it for [hop].
  final ValueChanged<bool> onAddKey;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final keys = context.watch<KeysProvider>().keys;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: LabeledField(
                label: t.editor.host,
                child: TextFormField(
                  controller: hop.host,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  decoration: InputDecoration(helperText: t.editor.hostHelper),
                  validator: (value) => _required(t, value),
                ),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 96,
              child: LabeledField(
                label: t.editor.port,
                child: TextFormField(
                  controller: hop.port,
                  keyboardType: TextInputType.number,
                  validator: (value) {
                    final port = int.tryParse(value?.trim() ?? '');
                    return port == null || port < 1 || port > 65535 ? t.editor.invalidPort : null;
                  },
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        LabeledField(
          label: t.editor.user,
          child: TextFormField(controller: hop.user, autocorrect: false, validator: (value) => _required(t, value)),
        ),
        const SizedBox(height: 12),
        LabeledField(
          label: t.editor.auth,
          child: AppSelect<AuthMethod>(
            expand: true,
            value: hop.auth,
            options: [
              for (final method in AuthMethod.values)
                if (method != AuthMethod.agent || isDesktop || hop.auth == AuthMethod.agent)
                  (method, authLabel(t, method)),
            ],
            onChanged: (method) {
              hop.auth = method;
              onChanged();
            },
          ),
        ),
        if (hop.auth == AuthMethod.agent) _Note(icon: Symbols.info, text: t.editor.agentHelp),
        if (hop.auth == AuthMethod.key) ...[
          const SizedBox(height: 12),
          if (keys.isEmpty)
            Text(t.editor.noKeys)
          else
            FormField<String>(
              validator: (_) => keys.any((k) => k.id == hop.keyId) ? null : t.editor.chooseKey,
              builder: (field) {
                final chosen = keys.any((k) => k.id == hop.keyId) ? hop.keyId : null;
                return LabeledField(
                  label: t.editor.key,
                  error: field.errorText,
                  child: AppSelect<String?>(
                    expand: true,
                    value: chosen,
                    options: [
                      if (chosen == null) (null, t.editor.chooseKey),
                      for (final key in keys) (key.id, '${key.name} · ${key.type}'),
                    ],
                    onChanged: (keyId) {
                      if (keyId == null) return;
                      hop.keyId = keyId;
                      field.didChange(keyId);
                      onChanged();
                    },
                  ),
                );
              },
            ),
          const SizedBox(height: AppSizes.gap),
          Wrap(
            spacing: AppSizes.gap,
            runSpacing: AppSizes.gap,
            children: [
              FilledButton.tonal(onPressed: () => onAddKey(false), child: Text(t.editor.importKey)),
              FilledButton.tonal(onPressed: () => onAddKey(true), child: Text(t.editor.generateKey)),
            ],
          ),
        ],
        if (hop.auth == AuthMethod.password) ...[
          const SizedBox(height: 12),
          LabeledField(
            label: t.editor.password,
            child: TextFormField(
              controller: hop.password,
              obscureText: true,
              decoration: InputDecoration(
                helperText: hop.hasSavedPassword ? t.editor.passwordSavedHint : t.editor.passwordAskHint,
              ),
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(t.editor.savePassword),
            value: hop.savePassword,
            onChanged: (value) {
              hop.savePassword = value ?? false;
              onChanged();
            },
          ),
        ],
      ],
    );
  }
}

String authLabel(Translations t, AuthMethod method) => switch (method) {
  AuthMethod.key => t.auth.key,
  AuthMethod.password => t.auth.password,
  AuthMethod.agent => t.auth.agent,
  AuthMethod.none => t.auth.none,
  AuthMethod.keyboardInteractive => t.auth.keyboardInteractive,
};

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        ],
      ),
    );
  }
}
