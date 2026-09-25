import 'dart:convert';

import 'package:omp_core/ssh.dart';

import '../database/app_database.dart';

/// What the app knows about the host key a server presented. Drives the trust dialog.
sealed class HostKeyVerdict {
  const HostKeyVerdict();
}

/// Matches a key the user trusted before, in the app or in `~/.ssh/known_hosts`.
final class HostKeyTrusted extends HostKeyVerdict {
  const HostKeyTrusted();
}

/// First contact: nothing is recorded for this host and port. Trust on first use asks the user.
final class HostKeyUnknown extends HostKeyVerdict {
  const HostKeyUnknown();
}

/// Differs from what is recorded: a reinstalled server, or someone in the middle.
final class HostKeyChanged extends HostKeyVerdict {
  const HostKeyChanged(this.knownFingerprints);

  /// Fingerprints the app trusts for this host and port; empty when only `~/.ssh/known_hosts` disagrees.
  final List<String> knownFingerprints;
}

/// Marked `@revoked` in `~/.ssh/known_hosts`. Never accepted.
final class HostKeyRevoked extends HostKeyVerdict {
  const HostKeyRevoked();
}

/// Judges [check] against the app's trusted keys and, on desktop, the OpenSSH verdict for the same key.
///
/// The app's own record wins over `~/.ssh/known_hosts`; any recorded key for the host and port that
/// differs from the presented one is a change, whatever its type.
HostKeyVerdict judgeHostKey(
  HostKeyCheck check,
  Iterable<KnownHostRow> trusted, {
  KnownHostStatus openSsh = KnownHostStatus.unknown,
}) {
  if (openSsh == KnownHostStatus.revoked) return const HostKeyRevoked();
  final blob = base64.encode(check.keyBlob);
  final recorded = [
    for (final row in trusted)
      if (row.host == check.host && row.port == check.port) row,
  ];
  if (recorded.any((row) => row.keyType == check.keyType && row.keyBlob == blob)) return const HostKeyTrusted();
  if (recorded.isNotEmpty) return HostKeyChanged([for (final row in recorded) row.fingerprint]);
  return switch (openSsh) {
    KnownHostStatus.match => const HostKeyTrusted(),
    KnownHostStatus.mismatch => const HostKeyChanged([]),
    KnownHostStatus.differentKeyType || KnownHostStatus.unknown => const HostKeyUnknown(),
    KnownHostStatus.revoked => const HostKeyRevoked(),
  };
}

KnownHostRow knownHostRow(HostKeyCheck check, DateTime addedAt) => KnownHostRow(
  host: check.host,
  port: check.port,
  keyType: check.keyType,
  keyBlob: base64.encode(check.keyBlob),
  fingerprint: check.sha256Fingerprint,
  addedAt: addedAt,
);

/// Rows for host keys delivered by the tailnet's control plane (`sshHostKeys`), so the first connection to a
/// Tailscale peer needs no prompt.
List<KnownHostRow> knownHostRowsFromLines(String host, int port, Iterable<String> authorizedKeyLines, DateTime addedAt) {
  final rows = <KnownHostRow>[];
  for (final line in authorizedKeyLines) {
    final key = SshPublicKey.parse(line);
    rows.add(
      KnownHostRow(
        host: host,
        port: port,
        keyType: key.type,
        keyBlob: base64.encode(key.blob),
        fingerprint: key.fingerprint,
        addedAt: addedAt,
      ),
    );
  }
  return rows;
}
