import '../database/app_database.dart';

/// Prefill for the machine editor, from `~/.ssh/config` or Tailscale discovery.
final class EndpointDraft {
  const EndpointDraft({required this.host, this.port = 22, required this.user, required this.auth, this.keyId});

  final String host;
  final int port;
  final String user;
  final AuthMethod auth;
  final String? keyId;
}

final class MachineDraft {
  const MachineDraft({
    required this.name,
    required this.target,
    this.jumps = const [],
    this.sshConfigAlias,
    this.tailscale = false,
    this.hostKeys = const [],
    this.ignoredProxyCommand,
  });

  final String name;
  final EndpointDraft target;
  final List<EndpointDraft> jumps;
  final String? sshConfigAlias;
  final bool tailscale;

  /// Host keys to trust when the machine is saved (Tailscale's control-plane keys).
  final List<KnownHostRow> hostKeys;

  /// A `ProxyCommand` from `~/.ssh/config`; the app dials directly or through jumps instead.
  final String? ignoredProxyCommand;
}
