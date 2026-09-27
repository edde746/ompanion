import 'dart:io';

import 'package:omp_core/ssh.dart';

/// Machines started by `harness/sshd/up.sh`; paths are relative to `packages/omp_core`, where
/// `dart test` runs.
const sshTestDir = '../../.tools/ssh-test';
const bastionPort = 22220;
const targetPort = 22221;
const passwordUser = 'pw';
const password = 'omp-test-password';
const sshdImage = 'omp-sshd:test';

String testPrivateKey([String name = 'id_ed25519']) => File('$sshTestDir/$name').readAsStringSync();

SshKeyAuth testKeyAuth([String name = 'id_ed25519']) => SshKeyAuth(testPrivateKey(name));

/// Trusts exactly the host keys up.sh recorded in `.tools/ssh-test/known_hosts`.
Future<bool> trustTestHosts(HostKeyCheck check) async =>
    checkKnownHost(parseKnownHosts(File('$sshTestDir/known_hosts').readAsStringSync()), check) == KnownHostStatus.match;

SshHop targetHop({SshAuth? auth, String user = 'omp'}) =>
    SshHop(host: 'localhost', port: targetPort, user: user, auth: auth ?? testKeyAuth());

/// Target through the bastion: the bastion resolves `target` on the docker network.
SshTarget targetViaBastion() => SshTarget(
  jumps: [SshHop(host: 'localhost', port: bastionPort, user: 'omp', auth: testKeyAuth())],
  target: SshHop(host: 'target', user: 'omp', auth: testKeyAuth()),
);

/// The address a server on this computer listens on for the test machines, which reach it as
/// `host.docker.internal`, Docker's host gateway (harness/sshd/up.sh). Docker on macOS runs in a VM that forwards the
/// gateway to the Mac's loopback; on Linux the gateway is an address of this computer, the default bridge's.
Future<String> hostGatewayAddress() async {
  if (Platform.isMacOS) return InternetAddress.loopbackIPv4.address;
  final result = await Process.run('docker', ['exec', 'omp-sshd-target', 'getent', 'ahostsv4', 'host.docker.internal']);
  if (result.exitCode != 0) throw StateError('resolving host.docker.internal on the target failed: ${result.stderr}');
  return (result.stdout as String).trim().split(RegExp(r'\s+')).first;
}
