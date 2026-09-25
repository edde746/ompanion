import 'dart:convert';

import 'package:omp_core/ssh.dart';
import 'package:omp_core/transport.dart';

import '../database/app_database.dart';
import '../models/machine.dart';
import 'known_hosts_store.dart';
import 'secret_store.dart';

/// UI callbacks a connection may need while dialing.
final class ConnectPrompts {
  const ConnectPrompts({required this.password, required this.keyboardInteractive, required this.hostKey});

  /// Asked for a hop with password auth and no saved password. Null cancels the connection.
  final Future<String?> Function(SshEndpoint hop) password;
  final KeyboardInteractiveHandler keyboardInteractive;
  final HostKeyPrompt hostKey;
}

/// The user dismissed a prompt the connection needed.
final class ConnectCancelled implements Exception {
  const ConnectCancelled();
}

/// Opens [HostLink]s to machines. Secrets are read from secure storage per connection, never cached.
class MachineConnector {
  MachineConnector(this._secrets, this._knownHosts);

  final SecretStore _secrets;
  final KnownHostsStore _knownHosts;

  /// Throws [MissingCredential], [ConnectCancelled], or the link's own connection errors.
  Future<HostLink> open(Machine machine, ConnectPrompts prompts) async {
    switch (machine) {
      case LocalMachine():
        return LocalLink();
      case SshMachine():
        final keys = <String, StoredPrivateKey>{};
        final passwords = <String, String>{};
        for (final hop in machine.hops) {
          switch (hop.auth) {
            case AuthMethod.key:
              final keyId = hop.keyId;
              final key = keyId == null ? null : await _secrets.privateKey(keyId);
              if (key != null) keys[keyId!] = key;
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
          ConnectionSecrets(keys: keys, passwords: passwords),
          keyboardInteractive: prompts.keyboardInteractive,
        );
        return SshLink.open(target, verifyHostKey: await _knownHosts.verifier(prompts.hostKey));
    }
  }
}

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
