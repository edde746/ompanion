import 'dart:convert';
import 'dart:io';

import 'package:omp_core/session.dart' show PermanentConnectFailure;
import 'package:omp_core/ssh.dart';
import 'package:omp_core/transport.dart';

import '../app/dev_overrides.dart';
import '../database/app_database.dart';
import '../models/machine.dart';
import 'known_hosts_store.dart';
import 'secret_store.dart';

/// UI callbacks a connection may need while dialing.
final class ConnectPrompts {
  const ConnectPrompts({
    required this.password,
    required this.keyboardInteractive,
    required this.hostKey,
    required this.passphrase,
  });

  /// Asked for a hop with password auth and no saved password. Null cancels the connection.
  final Future<String?> Function(SshEndpoint hop) password;
  final KeyboardInteractiveHandler keyboardInteractive;
  final HostKeyPrompt hostKey;

  /// Asked for an encrypted identity file's passphrase, and whether to keep it in secure storage. Null cancels the
  /// connection.
  final Future<({String passphrase, bool remember})?> Function(KeyPassphraseRequest request) passphrase;
}

/// The user dismissed a prompt the connection needed. Permanent: a session that reconnects in the background stops
/// instead of asking again every few seconds.
final class ConnectCancelled implements PermanentConnectFailure {
  const ConnectCancelled();
}

/// Opens [HostLink]s to machines. Secrets are read from secure storage per connection, never cached.
class MachineConnector {
  /// [keyName] names a stored key by id in errors.
  MachineConnector(this._secrets, this._knownHosts, {Future<String?> Function(String keyId)? keyName})
    : _keyName = keyName ?? ((_) async => null);

  final SecretStore _secrets;
  final KnownHostsStore _knownHosts;
  final Future<String?> Function(String keyId) _keyName;

  /// Throws [MissingCredential], [ConnectCancelled], or the link's own connection errors.
  Future<HostLink> open(Machine machine, ConnectPrompts prompts) async {
    switch (machine) {
      case LocalMachine():
        return LocalLink(environment: devLocalEnvironment);
      case SshMachine():
        final keys = <String, StoredPrivateKey>{};
        final keyNames = <String, String>{};
        final passwords = <String, String>{};
        for (final hop in machine.hops) {
          switch (hop.auth) {
            case AuthMethod.key:
              final keyId = hop.keyId;
              if (keyId == null) continue;
              final key = await _secrets.privateKey(keyId);
              if (key != null) keys[keyId] = key;
              final name = await _keyName(keyId);
              if (name != null) keyNames[keyId] = name;
            case AuthMethod.password:
              final password = await _secrets.password(hop.id) ?? await prompts.password(hop);
              if (password == null) throw const ConnectCancelled();
              passwords[hop.id] = password;
            case AuthMethod.agent || AuthMethod.none || AuthMethod.keyboardInteractive:
              break;
          }
        }
        final target = sshTargetFor(
          machine,
          ConnectionSecrets(keys: keys, keyNames: keyNames, passwords: passwords),
          keyboardInteractive: prompts.keyboardInteractive,
          passphrase: keptPassphrases(_secrets, prompts.passphrase),
          sshConfig: _sshConfig,
        );
        return SshLink.open(target, verifyHostKey: await _knownHosts.verifier(prompts.hostKey));
    }
  }

  /// `ssh`'s own config, home and environment, except while this computer runs with an isolated home
  /// ([devLocalHome]): then `<home>/.ssh/config` and the isolated environment, so the user's keys and agent stay out.
  static SshClientConfig get _sshConfig {
    final home = devLocalHome;
    if (home == null) return const SshClientConfig();
    final config = File('$home/.ssh/config');
    return SshClientConfig(
      configFile: config.existsSync() ? config.path : '/dev/null',
      home: home,
      environment: devLocalEnvironment,
    );
  }

  /// Whether the probe of [machine] may take omp from PATH and the system directories. Not for this computer while it
  /// runs with an isolated home ([devLocalHome]): the user's own omp there is off limits.
  bool searchSystemPaths(Machine machine) => !(machine is LocalMachine && devLocalHome != null);
}

/// Passphrases of encrypted identity files: one kept in [secrets] for the key is tried first, and forgotten once it no
/// longer decrypts the key; then [ask] asks, and the answer is kept when the user chose to. Throws [ConnectCancelled]
/// when the user dismisses the prompt.
KeyPassphraseHandler keptPassphrases(
  SecretStore secrets,
  Future<({String passphrase, bool remember})?> Function(KeyPassphraseRequest request) ask,
) => (request) async {
  final fingerprint = request.publicKey?.fingerprint;
  if (fingerprint != null) {
    if (!request.wrong) {
      final kept = await secrets.keyFilePassphrase(fingerprint);
      if (kept != null) return kept;
    } else {
      await secrets.deleteKeyFilePassphrase(fingerprint);
    }
  }
  final answer = await ask(request);
  if (answer == null) throw const ConnectCancelled();
  if (answer.remember && fingerprint != null) await secrets.saveKeyFilePassphrase(fingerprint, answer.passphrase);
  return answer.passphrase;
};

/// Runs `echo ok` on [link] and returns the round trip. Throws [HostLinkException] on any other reply.
Future<Duration> testConnection(HostLink link) async {
  final watch = Stopwatch()..start();
  final process = await link.exec('echo ok');
  await process.closeStdin();
  final (output, _, exit) = await (utf8.decodeStream(process.stdout), process.stderr.drain<void>(), process.exit).wait;
  final lines = [
    for (final line in const LineSplitter().convert(output))
      if (line.trim().isNotEmpty) line.trim(),
  ];
  if (exit.code != 0 || lines.isEmpty || lines.last != 'ok') {
    throw HostLinkException('unexpected reply to "echo ok" ($exit): ${output.trim()}');
  }
  return watch.elapsed;
}
