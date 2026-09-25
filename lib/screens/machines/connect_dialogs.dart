import 'package:flutter/material.dart';
import 'package:omp_core/ssh.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../models/host_key_trust.dart';
import '../../models/machine.dart';
import '../../services/machine_connector.dart';

/// Opens a link to [machine] with dialogs for passwords, keyboard-interactive prompts and host keys, runs
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
    return showDialog<String>(context: context, builder: (_) => PasswordDialog(hop: hop.label));
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
);

String describeConnectError(Translations t, Object error) => switch (error) {
  MissingCredential(:final endpoint, :final problem) => switch (problem) {
    CredentialProblem.noKeySelected => t.connectError.noKeySelected(hop: endpoint.label),
    CredentialProblem.keyMissing => t.connectError.keyMissing(hop: endpoint.label),
    CredentialProblem.passwordMissing => t.connectError.passwordMissing(hop: endpoint.label),
  },
  ConnectCancelled() => t.common.cancelled,
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
    final mono = theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace');
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
      iconColor: warning ? theme.colorScheme.error : null,
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
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
              foregroundColor: theme.colorScheme.onError,
            ),
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
      content: TextField(
        controller: _password,
        autofocus: true,
        obscureText: true,
        decoration: InputDecoration(labelText: t.editor.password),
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.common.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _password.text), child: Text(t.common.continueAction)),
      ],
    );
  }
}

/// Asks a keyboard-interactive [request]'s prompts. Pops the answers, or null to cancel.
class KeyboardInteractiveDialog extends StatefulWidget {
  const KeyboardInteractiveDialog(this.request, {super.key});

  final KeyboardInteractiveRequest request;

  @override
  State<KeyboardInteractiveDialog> createState() => _KeyboardInteractiveDialogState();
}

class _KeyboardInteractiveDialogState extends State<KeyboardInteractiveDialog> {
  late final List<TextEditingController> _answers = [
    for (final _ in widget.request.prompts) TextEditingController(),
  ];

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
    final request = widget.request;
    return AlertDialog(
      title: Text(request.name.isEmpty ? t.auth.keyboardInteractive : request.name),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (request.instruction.isNotEmpty) Text(request.instruction),
          for (final (index, prompt) in request.prompts.indexed)
            TextField(
              controller: _answers[index],
              autofocus: index == 0,
              obscureText: !prompt.echo,
              decoration: InputDecoration(labelText: prompt.text.trim()),
              onSubmitted: index == request.prompts.length - 1 ? (_) => _submit() : null,
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
