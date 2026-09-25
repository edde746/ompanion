import 'package:omp_core/session.dart' show PermanentConnectFailure;
import 'package:omp_core/ssh.dart';

import '../database/app_database.dart';

/// One SSH server in a machine's path, as stored. [id] is the owner of the hop's saved password in secure
/// storage: the machine id for the target, the jump row id for a jump host.
final class SshEndpoint {
  const SshEndpoint({
    required this.id,
    required this.host,
    this.port = 22,
    required this.user,
    required this.auth,
    this.keyId,
  });

  final String id;
  final String host;
  final int port;
  final String user;
  final AuthMethod auth;

  /// Set when [auth] is [AuthMethod.key]; null there means the key was deleted or never chosen.
  final String? keyId;

  String get label => port == 22 ? '$user@$host' : '$user@$host:$port';
}

sealed class Machine {
  const Machine({required this.id, required this.name, required this.createdAt, required this.updatedAt});

  final String id;
  final String name;
  final DateTime createdAt;
  final DateTime updatedAt;
}

/// This computer, driven through `Process` and local files.
final class LocalMachine extends Machine {
  const LocalMachine({required super.id, required super.name, required super.createdAt, required super.updatedAt});
}

final class SshMachine extends Machine {
  const SshMachine({
    required super.id,
    required super.name,
    required super.createdAt,
    required super.updatedAt,
    required this.target,
    this.jumps = const [],
    this.sshConfigAlias,
    this.tailscale = false,
  });

  final SshEndpoint target;

  /// Jump hosts in dial order.
  final List<SshEndpoint> jumps;

  /// The `~/.ssh/config` alias this machine was imported from.
  final String? sshConfigAlias;

  /// Reached over the tailnet: [target] host is a MagicDNS name or a 100.x address.
  final bool tailscale;

  List<SshEndpoint> get hops => [...jumps, target];
}

/// Reads a machine from its row and its jump rows (any order).
Machine machineFromRows(MachineRow row, Iterable<MachineJumpRow> jumps) {
  switch (row.kind) {
    case MachineKind.local:
      return LocalMachine(id: row.id, name: row.name, createdAt: row.createdAt, updatedAt: row.updatedAt);
    case MachineKind.ssh:
      final host = row.host;
      final user = row.user;
      final auth = row.auth;
      if (host == null || user == null || auth == null) {
        throw FormatException('SSH machine ${row.id} lacks host, user or auth');
      }
      final ordered = jumps.toList()..sort((a, b) => a.position.compareTo(b.position));
      return SshMachine(
        id: row.id,
        name: row.name,
        createdAt: row.createdAt,
        updatedAt: row.updatedAt,
        target: SshEndpoint(id: row.id, host: host, port: row.port, user: user, auth: auth, keyId: row.keyId),
        jumps: [
          for (final jump in ordered)
            SshEndpoint(
              id: jump.id,
              host: jump.host,
              port: jump.port,
              user: jump.user,
              auth: jump.auth,
              keyId: jump.keyId,
            ),
        ],
        sshConfigAlias: row.sshConfigAlias,
        tailscale: row.tailscale,
      );
  }
}

MachineRow machineRow(Machine machine) => switch (machine) {
  LocalMachine() => MachineRow(
    id: machine.id,
    name: machine.name,
    kind: MachineKind.local,
    port: 22,
    tailscale: false,
    createdAt: machine.createdAt,
    updatedAt: machine.updatedAt,
  ),
  SshMachine(:final target) => MachineRow(
    id: machine.id,
    name: machine.name,
    kind: MachineKind.ssh,
    host: target.host,
    port: target.port,
    user: target.user,
    auth: target.auth,
    keyId: target.keyId,
    sshConfigAlias: machine.sshConfigAlias,
    tailscale: machine.tailscale,
    createdAt: machine.createdAt,
    updatedAt: machine.updatedAt,
  ),
};

List<MachineJumpRow> machineJumpRows(Machine machine) => switch (machine) {
  LocalMachine() => const [],
  SshMachine(:final jumps) => [
    for (final (position, jump) in jumps.indexed)
      MachineJumpRow(
        id: jump.id,
        machineId: machine.id,
        position: position,
        host: jump.host,
        port: jump.port,
        user: jump.user,
        auth: jump.auth,
        keyId: jump.keyId,
      ),
  ],
};

/// A private key as kept in secure storage.
final class StoredPrivateKey {
  const StoredPrivateKey(this.pem, {this.passphrase});

  final String pem;
  final String? passphrase;
}

/// Secret material for one connection attempt, read from secure storage or asked for right before dialing.
final class ConnectionSecrets {
  const ConnectionSecrets({this.keys = const {}, this.passwords = const {}});

  /// Private keys by key id.
  final Map<String, StoredPrivateKey> keys;

  /// Passwords by [SshEndpoint.id].
  final Map<String, String> passwords;
}

enum CredentialProblem { noKeySelected, keyMissing, passwordMissing }

/// A hop cannot be dialed because a credential it needs is absent. Retrying cannot help, so a session stops
/// reconnecting on it.
final class MissingCredential implements PermanentConnectFailure {
  const MissingCredential(this.endpoint, this.problem);

  final SshEndpoint endpoint;
  final CredentialProblem problem;

  @override
  String toString() => 'MissingCredential(${endpoint.label}: ${problem.name})';
}

/// The dial plan for [machine]. Throws [MissingCredential] for the first hop whose secret is absent.
SshTarget sshTargetFor(
  SshMachine machine,
  ConnectionSecrets secrets, {
  required KeyboardInteractiveHandler keyboardInteractive,
}) {
  SshHop hop(SshEndpoint endpoint) => SshHop(
    host: endpoint.host,
    port: endpoint.port,
    user: endpoint.user,
    auth: _auth(endpoint, secrets, keyboardInteractive),
  );
  return SshTarget(jumps: [for (final jump in machine.jumps) hop(jump)], target: hop(machine.target));
}

SshAuth _auth(SshEndpoint endpoint, ConnectionSecrets secrets, KeyboardInteractiveHandler keyboardInteractive) {
  switch (endpoint.auth) {
    case AuthMethod.key:
      final keyId = endpoint.keyId;
      if (keyId == null) throw MissingCredential(endpoint, CredentialProblem.noKeySelected);
      final key = secrets.keys[keyId];
      if (key == null) throw MissingCredential(endpoint, CredentialProblem.keyMissing);
      return SshKeyAuth(key.pem, passphrase: key.passphrase);
    case AuthMethod.password:
      final password = secrets.passwords[endpoint.id];
      if (password == null) throw MissingCredential(endpoint, CredentialProblem.passwordMissing);
      return SshPasswordAuth(password);
    case AuthMethod.agent:
      return const SshAgentAuth();
    case AuthMethod.none:
      return const SshNoneAuth();
    case AuthMethod.keyboardInteractive:
      return SshKeyboardInteractiveAuth(keyboardInteractive);
  }
}
