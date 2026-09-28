import 'dart:io';

import 'package:omp_core/transport.dart';
import 'package:path/path.dart' as p;

import '../models/tailscale_status.dart';

sealed class TailscaleLookup {
  const TailscaleLookup();
}

final class TailscaleNotInstalled extends TailscaleLookup {
  const TailscaleNotInstalled();
}

/// The CLI exists but failed, e.g. the daemon is not running.
final class TailscaleFailed extends TailscaleLookup {
  const TailscaleFailed(this.message);

  final String message;
}

final class TailscaleFound extends TailscaleLookup {
  const TailscaleFound(this.status);

  final TailscaleStatus status;
}

const _macAppBinary = '/Applications/Tailscale.app/Contents/MacOS/Tailscale';

/// Runs `tailscale status --json` with the desktop's Tailscale client.
Future<TailscaleLookup> readTailscaleStatus() async {
  final binary = await _findBinary();
  if (binary == null) return const TailscaleNotInstalled();
  final result = await runOnHost(
    binary,
    const ['status', '--json'],
    // The Mac app's binary acts as the CLI only with this variable set.
    environment: binary == _macAppBinary ? const {'TAILSCALE_BE_CLI': '1'} : null,
  );
  final stdout = result.stdout as String;
  if (result.exitCode != 0 && stdout.trim().isEmpty) {
    final stderr = (result.stderr as String).trim();
    return TailscaleFailed(stderr.isEmpty ? 'exit ${result.exitCode}' : stderr);
  }
  return TailscaleFound(parseTailscaleStatus(stdout));
}

Future<String?> _findBinary() async {
  // A Flatpak's PATH and /usr are the runtime's; the CLI is on the host's PATH.
  if (inFlatpak) {
    final result = await runOnHost('sh', const ['-c', 'command -v tailscale']);
    final path = (result.stdout as String).trim();
    return result.exitCode == 0 && path.startsWith('/') ? path : null;
  }
  if (Platform.isMacOS && File(_macAppBinary).existsSync()) return _macAppBinary;
  final name = Platform.isWindows ? 'tailscale.exe' : 'tailscale';
  // GUI apps on macOS start with a minimal PATH that lacks Homebrew's prefixes.
  final extra = switch (Platform.operatingSystem) {
    'macos' => const ['/opt/homebrew/bin', '/usr/local/bin'],
    'windows' => [p.join(Platform.environment['ProgramFiles'] ?? r'C:\Program Files', 'Tailscale')],
    _ => const <String>[],
  };
  final path = Platform.environment['PATH'] ?? '';
  for (final dir in [...path.split(Platform.isWindows ? ';' : ':'), ...extra]) {
    if (dir.isEmpty) continue;
    final candidate = p.join(dir, name);
    if (File(candidate).existsSync()) return candidate;
  }
  return null;
}
