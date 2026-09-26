import 'dart:io';

import 'package:omp_core/ssh.dart';

/// This Windows computer over its own Win32-OpenSSH server at localhost:22, as the CI Windows host job sets it up
/// (.github/workflows/ci.yml): key authentication for the current user with the private key at
/// `OMPANION_WINDOWS_SSH_KEY`, and the server's host keys in `OMPANION_WINDOWS_KNOWN_HOSTS`. The tests run on the
/// machine they reach, so they also prepare it with local file operations.
String _setting(String name) =>
    Platform.environment[name] ?? (throw StateError('$name is not set; see the Windows host job in ci.yml'));

SshTarget windowsTarget() => SshTarget(
  target: SshHop(
    host: 'localhost',
    user: Platform.environment['USERNAME']!,
    auth: SshKeyAuth(File(_setting('OMPANION_WINDOWS_SSH_KEY')).readAsStringSync()),
  ),
);

Future<bool> _trusted(HostKeyCheck check) async =>
    checkKnownHost(parseKnownHosts(File(_setting('OMPANION_WINDOWS_KNOWN_HOSTS')).readAsStringSync()), check) ==
    KnownHostStatus.match;

Future<SshLink> connectWindows() => SshLink.open(windowsTarget(), verifyHostKey: _trusted);
