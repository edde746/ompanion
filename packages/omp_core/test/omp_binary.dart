import 'dart:ffi';
import 'dart:io';

import 'package:omp_core/host.dart';

/// Repository root; tests run from packages/omp_core.
final String repoRoot = Directory.current.parent.parent.path;

/// An omp 18.3.1 release asset in `.tools/`, where `scripts/fetch_omp.sh` puts it.
String ompAsset(String name) => '$repoRoot/.tools/omp/18.3.1/$name';

/// This computer as a probe of it reads (glibc on Linux); its [HostProbe.releaseAsset] names [ompBinary].
final HostProbe thisComputer = HostProbe(
  commandShell: CommandShell.posix,
  os: Platform.isMacOS ? HostOs.macos : HostOs.linux,
  kernel: Platform.isMacOS ? 'Darwin' : 'Linux',
  arch: switch (Abi.current()) {
    Abi.macosArm64 || Abi.linuxArm64 => 'arm64',
    Abi.macosX64 || Abi.linuxX64 => 'x64',
    final abi => throw UnsupportedError('omp 18.3.1 has no build for $abi'),
  },
  libc: Platform.isLinux ? 'glibc' : null,
  home: '/unused',
  agentDir: '/unused',
);

/// The omp 18.3.1 release binary for this computer.
String get ompBinary => ompAsset(thisComputer.releaseAsset!);

/// The architecture of the Docker test machines as omp names it: Docker's server architecture, mapped as
/// harness/sshd/up.sh maps it.
Future<String> dockerArch() async {
  final result = await Process.run('docker', ['version', '--format', '{{.Server.Arch}}']);
  if (result.exitCode != 0) throw StateError('docker version failed: ${result.stderr}');
  return switch ((result.stdout as String).trim()) {
    'arm64' || 'aarch64' => 'arm64',
    'amd64' || 'x86_64' => 'x64',
    final arch => throw UnsupportedError('omp 18.3.1 has no build for docker architecture $arch'),
  };
}
