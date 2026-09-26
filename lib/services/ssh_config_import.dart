import 'dart:io';

import 'package:omp_core/ssh.dart';

import '../database/app_database.dart';
import '../models/machine_draft.dart';

/// OpenSSH follows ProxyJump chains without a limit; a cycle in the config would never end.
const _maxJumpDepth = 8;

/// Editor prefill for a `~/.ssh/config` alias, from `ssh -G` (desktop).
///
/// ProxyJump hops are resolved through their own config, like `ssh` does, and a hop's own ProxyJump is
/// dialed before it. A hop whose identity file matches a stored key uses that key; otherwise SSH config and agent auth.
Future<MachineDraft> draftFromSshAlias(String alias, {required List<SshKeyRow> keys}) async {
  final config = await resolveSshAlias(alias);
  final fingerprints = {for (final key in keys) key.fingerprint: key.id};
  return MachineDraft(
    name: alias,
    target: await _endpoint(config, fingerprints),
    jumps: await _jumps(config, fingerprints, 0),
    sshConfigAlias: alias,
    ignoredProxyCommand: config.proxyCommand,
  );
}

Future<List<EndpointDraft>> _jumps(SshResolvedHost config, Map<String, String> fingerprints, int depth) async {
  if (config.proxyJump.isEmpty) return const [];
  if (depth == _maxJumpDepth) throw FormatException('ProxyJump chain deeper than $_maxJumpDepth hops');
  final jumps = <EndpointDraft>[];
  for (final spec in config.proxyJump) {
    final hop = await resolveSshAlias(spec.host, user: spec.user, port: spec.port);
    jumps
      ..addAll(await _jumps(hop, fingerprints, depth + 1))
      ..add(await _endpoint(hop, fingerprints));
  }
  return jumps;
}

Future<EndpointDraft> _endpoint(SshResolvedHost config, Map<String, String> fingerprints) async {
  final keyId = await _storedKeyFor(config.identityFiles, fingerprints);
  return EndpointDraft(
    host: config.hostname,
    port: config.port,
    user: config.user,
    auth: keyId == null ? AuthMethod.agent : AuthMethod.key,
    keyId: keyId,
  );
}

/// The id of a stored key whose public half matches one of [identityFiles] (via the `.pub` next to it).
Future<String?> _storedKeyFor(List<String> identityFiles, Map<String, String> fingerprints) async {
  final home = Platform.environment[Platform.isWindows ? 'USERPROFILE' : 'HOME'] ?? '';
  for (final path in identityFiles) {
    final publicKey = File('${expandHome(path, home)}.pub');
    if (!await publicKey.exists()) continue;
    final SshPublicKey key;
    try {
      key = SshPublicKey.parse(await publicKey.readAsString());
    } on FormatException {
      // ssh skips an unreadable `.pub` next to an identity file too.
      continue;
    }
    final keyId = fingerprints[key.fingerprint];
    if (keyId != null) return keyId;
  }
  return null;
}
