import 'dart:typed_data';

import 'keys.dart';

/// The SSH path to a machine: zero or more jump hosts, in dial order, then the target.
///
/// Each jump is dialed from the previous hop with `direct-tcpip`, so [SshHop.host] of a later hop is
/// resolved by the hop before it (a reverse tunnel is a jump to the relay, then `localhost:<port>`).
final class SshTarget {
  const SshTarget({this.jumps = const [], required this.target});

  final List<SshHop> jumps;
  final SshHop target;

  List<SshHop> get hops => [...jumps, target];

  String get label => target.label;
}

/// One SSH server in a connection path, with its own credentials.
final class SshHop {
  const SshHop({required this.host, this.port = 22, required this.user, required this.auth});

  final String host;
  final int port;
  final String user;
  final SshAuth auth;

  String get label => port == 22 ? '$user@$host' : '$user@$host:$port';
}

/// How a hop proves the user's identity. `none` is tried last after any other method.
sealed class SshAuth {
  const SshAuth();
}

/// An OpenSSH (`-----BEGIN OPENSSH PRIVATE KEY-----`) or PEM private key, optionally encrypted.
final class SshKeyAuth extends SshAuth {
  const SshKeyAuth(this.privateKeyPem, {this.passphrase, this.name, this.fallback});

  final String privateKeyPem;
  final String? passphrase;

  /// What the user calls the key, for errors.
  final String? name;

  /// Answers the server's password and keyboard-interactive prompts once it refused the key, like `ssh` does.
  /// Null ends the attempt with the refusal.
  final KeyboardInteractiveHandler? fallback;
}

final class SshPasswordAuth extends SshAuth {
  const SshPasswordAuth(this.password);

  final String password;
}

/// Keys as the `ssh` command offers them to the hop (desktop): the agent's, then the identity files, as
/// `ssh -G` resolves `IdentityAgent`, `IdentityFile` and `IdentitiesOnly` for it (see [sshIdentities]).
final class SshConfigAuth extends SshAuth {
  const SshConfigAuth({this.alias, this.config = const SshClientConfig(), this.passphrase, this.fallback});

  /// The name `ssh` would be given for the hop when it is not the host, e.g. a `~/.ssh/config` alias.
  final String? alias;

  final SshClientConfig config;

  /// Unlocks an encrypted identity file once the server accepted its public key, like `ssh` asks. Null fails
  /// such a key as unusable.
  final KeyPassphraseHandler? passphrase;

  /// As [SshKeyAuth.fallback], after the server refused every key or none was found.
  final KeyboardInteractiveHandler? fallback;
}

/// Where the OpenSSH client settings come from. Null fields mean what `ssh` itself uses: `~/.ssh/config`, this
/// process's home directory and environment.
final class SshClientConfig {
  const SshClientConfig({this.configFile, this.home, this.environment});

  /// Passed to `ssh -G -F`.
  final String? configFile;

  /// Expands `~` and `%d` in identity file and agent paths.
  final String? home;

  /// `SSH_AUTH_SOCK`, `IdentityAgent $VAR` and `%u` are read here.
  final Map<String, String>? environment;
}

/// Answers an [KeyPassphraseRequest]: the passphrase, or null to give up on the key. A handler may throw to end the
/// connection attempt with its own error.
typedef KeyPassphraseHandler = Future<String?> Function(KeyPassphraseRequest request);

/// An encrypted identity file to unlock: once the server accepted its public key, or before offering it when its
/// public key is unknown (an encrypted PEM key without a `.pub`), as `ssh` does.
final class KeyPassphraseRequest {
  const KeyPassphraseRequest({required this.hop, required this.path, this.publicKey, this.wrong = false});

  /// [SshHop.label] of the hop the key is for.
  final String hop;

  /// As `~/.ssh/config` names the file.
  final String path;
  final SshPublicKey? publicKey;

  /// The previous answer did not decrypt the key.
  final bool wrong;
}

/// A key offered to a hop.
final class SshOfferedKey {
  const SshOfferedKey(this.publicKey, {this.name, this.path, this.agent = false});

  final SshPublicKey publicKey;

  /// [SshKeyAuth.name] of a stored key.
  final String? name;

  /// The identity file, as `~/.ssh/config` names it.
  final String? path;

  /// The ssh-agent signs with it.
  final bool agent;

  /// `'id_work' (ED25519 SHA256:…)`, `~/.ssh/id_rsa (RSA SHA256:…)` or `agent key me@laptop (ED25519 SHA256:…)`.
  String describe() {
    final label = switch (this) {
      SshOfferedKey(:final name?) => "'$name'",
      SshOfferedKey(:final path?) => path,
      SshOfferedKey(agent: true) => 'agent key ${publicKey.comment}'.trim(),
      _ => publicKey.comment.isEmpty ? 'key' : "'${publicKey.comment}'",
    };
    return '$label (${keyTypeLabel(publicKey.type)} ${publicKey.fingerprint})';
  }
}

/// What a hop was offered before it refused, or where keys were looked for when there were none.
final class SshKeyOffer {
  const SshKeyOffer({
    this.keys = const [],
    this.agentProblem,
    this.missingFiles = const [],
    this.unusableFiles = const [],
  });

  /// In the order they were offered.
  final List<SshOfferedKey> keys;

  /// Why the ssh-agent offered no key (not set, `IdentityAgent none`, unreachable, empty); null when it had keys or
  /// the hop does not use it.
  final String? agentProblem;

  /// Identity files that do not exist, as `~/.ssh/config` names them.
  final List<String> missingFiles;

  /// Identity files that exist but cannot be used here, e.g. security-key (`-sk`) keys, with the reason.
  final List<({String path, String reason})> unusableFiles;

  /// One line for errors: which keys, or why there were none.
  String describe() {
    if (keys.isNotEmpty) {
      return keys.length == 1 ? 'did not accept ${keys.single.describe()}' : 'accepted none of ${keys.length} keys';
    }
    return [
      'no key to offer',
      ?agentProblem,
      if (missingFiles.isNotEmpty) 'not found: ${missingFiles.join(', ')}',
      for (final file in unusableFiles) '${file.path}: ${file.reason}',
    ].join('; ');
  }
}

/// No credentials: the server decides from the network identity (Tailscale SSH).
final class SshNoneAuth extends SshAuth {
  const SshNoneAuth();
}

/// RFC 4256 prompts answered by [respond], e.g. password plus one-time code.
final class SshKeyboardInteractiveAuth extends SshAuth {
  const SshKeyboardInteractiveAuth(this.respond);

  final KeyboardInteractiveHandler respond;
}

/// Answers one keyboard-interactive round, one response per prompt in order. Null gives up.
typedef KeyboardInteractiveHandler = Future<List<String>?> Function(KeyboardInteractiveRequest request);

final class KeyboardInteractiveRequest {
  const KeyboardInteractiveRequest({
    required this.hop,
    required this.name,
    required this.instruction,
    required this.prompts,
    this.password = false,
    this.refused,
  });

  /// [SshHop.label] of the asking hop.
  final String hop;
  final String name;
  final String instruction;
  final List<KeyboardInteractivePrompt> prompts;

  /// The server's `password` method rather than keyboard-interactive: one secret prompt.
  final bool password;

  /// Set when the server asks after refusing these keys ([SshKeyAuth.fallback]).
  final SshKeyOffer? refused;
}

final class KeyboardInteractivePrompt {
  const KeyboardInteractivePrompt(this.text, {required this.echo});

  final String text;

  /// False for secrets: the UI must not show what is typed.
  final bool echo;
}

/// Decides whether to trust the host key a hop presented. False aborts the connection.
typedef HostKeyVerifier = Future<bool> Function(HostKeyCheck check);

final class HostKeyCheck {
  const HostKeyCheck({
    required this.host,
    required this.port,
    required this.keyType,
    required this.keyBlob,
    required this.sha256Fingerprint,
  });

  /// The host name as dialed, which is what `known_hosts` records.
  final String host;
  final int port;

  /// Key type from the blob, e.g. `ssh-ed25519`, `ssh-rsa`, `ecdsa-sha2-nistp256`.
  final String keyType;

  /// Public key in SSH wire format (the base64 field of a `known_hosts` line).
  final Uint8List keyBlob;

  /// OpenSSH form: `SHA256:` plus unpadded base64.
  final String sha256Fingerprint;
}
