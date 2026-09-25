import 'dart:typed_data';

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
  const SshKeyAuth(this.privateKeyPem, {this.passphrase});

  final String privateKeyPem;
  final String? passphrase;
}

final class SshPasswordAuth extends SshAuth {
  const SshPasswordAuth(this.password);

  final String password;
}

/// Keys held by a running ssh-agent (desktop).
final class SshAgentAuth extends SshAuth {
  /// Null means `$SSH_AUTH_SOCK` (POSIX) or the OpenSSH agent pipe (Windows).
  const SshAgentAuth([this.socketPath]);

  final String? socketPath;
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
  const KeyboardInteractiveRequest({required this.name, required this.instruction, required this.prompts});

  final String name;
  final String instruction;
  final List<KeyboardInteractivePrompt> prompts;
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
