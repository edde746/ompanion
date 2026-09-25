import 'dart:io';

import 'package:omp_core/ssh.dart';

/// Machines started by `testing/sshd/up.sh`; paths are relative to `packages/omp_core`, where
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
