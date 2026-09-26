import 'package:flutter/material.dart';
import 'package:omp_core/ssh.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

import '../../app/theme.dart';
import '../../i18n/strings.g.dart';
import '../../models/host_key_trust.dart';
import '../../models/machine.dart';
import '../../services/machine_connector.dart';
import '../../widgets/labeled_field.dart';
import '../chat/transcript/code_style.dart';

/// Opens a link to [machine] with dialogs for passwords, keyboard-interactive prompts, passphrases and host keys, runs
/// [action] on it, and closes the link.
Future<T> runOnMachine<T>(BuildContext context, Machine machine, Future<T> Function(HostLink link) action) async {
  final link = await context.read<MachineConnector>().open(machine, dialogConnectPrompts(context));
  try {
    return await action(link);
  } finally {
    await link.close();
  }
}

/// Prompts shown over [context]. A prompt raised after [context] is gone cancels the connection.
ConnectPrompts dialogConnectPrompts(BuildContext context) => ConnectPrompts(
  password: (hop) async {
    if (!context.mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (_) => PasswordDialog(hop: hop.label),
    );
  },
  keyboardInteractive: (request) async {
    if (!context.mounted) return null;
    return showDialog<List<String>>(context: context, builder: (_) => KeyboardInteractiveDialog(request));
  },
  hostKey: (check, verdict) async {
    if (!context.mounted) return false;
    final trusted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => HostKeyDialog(check: check, verdict: verdict),
    );
    return trusted ?? false;
  },
  passphrase: (request) async {
    if (!context.mounted) return null;
    return showDialog<({String passphrase, bool remember})>(
      context: context,
      builder: (_) => PassphraseDialog(request),
    );
  },
);

String describeConnectError(Translations t, Object error) => switch (error) {
  MissingCredential(:final endpoint, :final problem) => switch (problem) {
    CredentialProblem.noKeySelected => t.connectError.noKeySelected(hop: endpoint.label),
    CredentialProblem.keyMissing => t.connectError.keyMissing(hop: endpoint.label),
    CredentialProblem.passwordMissing => t.connectError.passwordMissing(hop: endpoint.label),
  },
  ConnectCancelled() => t.common.cancelled,
  SshConnectException(:final hop, failure: SshFailure.authFailed, offer: final offer?) when offer.keys.isNotEmpty => [
    describeRefusal(t, hop.host, offer),
    t.connectError.authorizedKeysHint(user: hop.user, host: hop.host),
  ].join('\n'),
  // The transport's line says where keys were looked for and why the agent had none.
  SshConnectException(:final hop, offer: final offer?) when offer.keys.isEmpty => [
    t.connectError.noKeys(host: hop.host),
    '$error',
  ].join('\n'),
  SshConnectException(:final hop, :final failure) => [
    switch (failure) {
      SshFailure.unreachable => t.connectError.unreachable(hop: hop.label),
      SshFailure.timeout => t.connectError.timeout(hop: hop.label),
      SshFailure.hostKeyRejected => t.connectError.hostKeyRejected(hop: hop.label),
      SshFailure.authFailed => t.connectError.authFailed(hop: hop.label),
      SshFailure.keyUnavailable => t.connectError.keyUnavailable(hop: hop.label),
      SshFailure.protocol => t.connectError.protocol(hop: hop.label),
    },
    // The transport's own wording names the underlying cause, e.g. "Connection refused".
    '$error',
  ].join('\n'),
  HostLinkException(:final message, :final cause) => cause == null ? message : '$message: $cause',
  _ => '$error',
};

/// Which keys [host] refused: `host.example.com did not accept the key 'id_work' (ED25519 SHA256:…).`
String describeRefusal(Translations t, String host, SshKeyOffer offer) {
  final keys = offer.keys;
  if (keys.length == 1) return t.connectError.keyRefused(host: host, key: _keyLabel(t, keys.single));
  if (keys.every((key) => key.agent && key.path == null)) {
    return t.connectError.agentKeysRefused(n: keys.length, host: host);
  }
  return [t.connectError.keysRefused(host: host), for (final key in keys) _keyLabel(t, key)].join('\n');
}

String _keyLabel(Translations t, SshOfferedKey key) {
  final comment = key.publicKey.comment;
  final what = switch (key) {
    SshOfferedKey(:final name?) => "'$name'",
    SshOfferedKey(:final path?) => path,
    SshOfferedKey(agent: true) =>
      comment.isEmpty ? t.connectError.agentKeyUnnamed : t.connectError.agentKey(comment: comment),
    _ => comment.isEmpty ? null : "'$comment'",
  };
  final fingerprint = '${keyTypeLabel(key.publicKey.type)} ${key.publicKey.fingerprint}';
  return what == null ? fingerprint : '$what ($fingerprint)';
}

/// Trust-on-first-use prompt, host-key-change warning, or revocation notice. Pops true to trust.
class HostKeyDialog extends StatelessWidget {
  const HostKeyDialog({super.key, required this.check, required this.verdict});

  final HostKeyCheck check;
  final HostKeyVerdict verdict;

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final host = check.port == 22 ? check.host : '${check.host}:${check.port}';
    final mono = codeTextStyle(theme).copyWith(fontSize: theme.textTheme.bodyMedium?.fontSize);
    final (title, body) = switch (verdict) {
      HostKeyUnknown() || HostKeyTrusted() => (t.hostKey.unknownTitle, t.hostKey.unknownBody(host: host)),
      HostKeyChanged(:final knownFingerprints) when knownFingerprints.isEmpty => (
        t.hostKey.changedTitle,
        t.hostKey.changedOpenSshBody(host: host),
      ),
      HostKeyChanged() => (t.hostKey.changedTitle, t.hostKey.changedBody(host: host)),
      HostKeyOtherTypesKnown() => (t.hostKey.otherTypesTitle, t.hostKey.otherTypesBody(host: host)),
      HostKeyRevoked() => (t.hostKey.revokedTitle, t.hostKey.revokedBody(host: host)),
    };
    final warning = verdict is! HostKeyUnknown;
    return AlertDialog(
      icon: Icon(warning ? Icons.gpp_bad_outlined : Icons.verified_user_outlined),
      iconColor: warning ? AppColors.of(context).error : null,
      title: Text(title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(body),
            const SizedBox(height: 16),
            Text(t.hostKey.keyType, style: theme.textTheme.labelMedium),
            SelectableText(check.keyType, style: mono),
            const SizedBox(height: 8),
            Text(t.hostKey.fingerprint, style: theme.textTheme.labelMedium),
            SelectableText(check.sha256Fingerprint, style: mono),
            if (verdict case HostKeyChanged(:final knownFingerprints) when knownFingerprints.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(t.hostKey.previouslyTrusted, style: theme.textTheme.labelMedium),
              for (final fingerprint in knownFingerprints) SelectableText(fingerprint, style: mono),
            ],
            if (verdict case HostKeyOtherTypesKnown(:final knownKeys)) ...[
              const SizedBox(height: 8),
              Text(t.hostKey.knownToOpenSsh, style: theme.textTheme.labelMedium),
              for (final key in knownKeys) SelectableText('${key.type} ${key.fingerprint}', style: mono),
            ],
          ],
        ),
      ),
      actions: switch (verdict) {
        HostKeyRevoked() => [TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.close))],
        HostKeyChanged() || HostKeyOtherTypesKnown() => [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: Text(verdict is HostKeyChanged ? t.hostKey.replace : t.hostKey.trust),
          ),
        ],
        HostKeyUnknown() || HostKeyTrusted() => [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(t.common.cancel)),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(t.hostKey.trust)),
        ],
      },
    );
  }
}

/// Asks for [hop]'s password. Pops it, or null to cancel.
class PasswordDialog extends StatefulWidget {
  const PasswordDialog({super.key, required this.hop});

  final String hop;

  @override
  State<PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<PasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      title: Text(t.prompt.passwordTitle(hop: widget.hop)),
      content: LabeledField(
        label: t.editor.password,
        child: TextField(
          controller: _password,
          autofocus: true,
          obscureText: true,
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _password.text), child: Text(t.common.continueAction)),
      ],
    );
  }
}

/// Asks a keyboard-interactive [request]'s prompts, or the server's password after refused keys. Pops the answers, or
/// null to cancel.
class KeyboardInteractiveDialog extends StatefulWidget {
  const KeyboardInteractiveDialog(this.request, {super.key});

  final KeyboardInteractiveRequest request;

  @override
  State<KeyboardInteractiveDialog> createState() => _KeyboardInteractiveDialogState();
}

class _KeyboardInteractiveDialogState extends State<KeyboardInteractiveDialog> {
  late final List<TextEditingController> _answers = [for (final _ in widget.request.prompts) TextEditingController()];

  @override
  void dispose() {
    for (final answer in _answers) {
      answer.dispose();
    }
    super.dispose();
  }

  void _submit() => Navigator.pop(context, [for (final answer in _answers) answer.text]);

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final request = widget.request;
    final refused = request.refused;
    return AlertDialog(
      title: Text(switch (request) {
        KeyboardInteractiveRequest(:final name) when name.isNotEmpty => name,
        KeyboardInteractiveRequest(password: true) => t.prompt.passwordTitle(hop: request.hop),
        _ => t.prompt.signInTitle(hop: request.hop),
      }),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (refused != null)
            Text(
              refused.keys.isEmpty
                  ? t.connectError.noKeys(host: request.hop)
                  : describeRefusal(t, request.hop, refused),
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          if (request.instruction.isNotEmpty) Text(request.instruction),
          for (final (index, prompt) in request.prompts.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: LabeledField(
                label: prompt.text.trim(),
                child: TextField(
                  controller: _answers[index],
                  autofocus: index == 0,
                  obscureText: !prompt.echo,
                  onSubmitted: index == request.prompts.length - 1 ? (_) => _submit() : null,
                ),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: _submit, child: Text(t.common.continueAction)),
      ],
    );
  }
}

/// Asks for the passphrase of an encrypted identity file from `~/.ssh/config`. Pops it with whether to keep it in
/// secure storage, or null to cancel.
class PassphraseDialog extends StatefulWidget {
  const PassphraseDialog(this.request, {super.key});

  final KeyPassphraseRequest request;

  @override
  State<PassphraseDialog> createState() => _PassphraseDialogState();
}

class _PassphraseDialogState extends State<PassphraseDialog> {
  final _passphrase = TextEditingController();
  var _remember = false;

  @override
  void dispose() {
    _passphrase.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, (passphrase: _passphrase.text, remember: _remember));

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    final theme = Theme.of(context);
    final request = widget.request;
    final key = request.publicKey;
    return AlertDialog(
      title: Text(t.prompt.passphraseTitle(path: request.path)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            key == null
                ? t.prompt.passphraseUnknownKey(hop: request.hop)
                : t.prompt.passphraseAccepted(hop: request.hop),
          ),
          if (key != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: SelectableText(
                '${keyTypeLabel(key.type)} ${key.fingerprint}',
                style: codeTextStyle(theme).copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            ),
          const SizedBox(height: 12),
          LabeledField(
            label: t.prompt.passphrase,
            error: request.wrong ? t.prompt.passphraseWrong : null,
            child: TextField(
              controller: _passphrase,
              autofocus: true,
              obscureText: true,
              onSubmitted: (_) => _submit(),
            ),
          ),
          // Without a public key there is no fingerprint to keep the passphrase under.
          if (key != null)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: Text(t.prompt.rememberPassphrase),
              value: _remember,
              onChanged: (value) => setState(() => _remember = value ?? false),
            ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: _submit, child: Text(t.common.continueAction)),
      ],
    );
  }
}
