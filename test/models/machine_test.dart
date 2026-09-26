import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/machine.dart';
import 'package:omp_core/ssh.dart';

void main() {
  final created = DateTime.utc(2026, 9, 1);
  final updated = DateTime.utc(2026, 9, 25);

  final machine = SshMachine(
    id: 'target',
    name: 'lab',
    createdAt: created,
    updatedAt: updated,
    target: const SshEndpoint(id: 'target', host: 'localhost', port: 2222, user: 'dev', auth: AuthMethod.password),
    jumps: const [
      SshEndpoint(id: 'jump-a', host: 'bastion.example.com', user: 'ops', auth: AuthMethod.key, keyId: 'key-a'),
      SshEndpoint(id: 'jump-b', host: 'relay', port: 2200, user: 'tunnel', auth: AuthMethod.agent),
    ],
    sshConfigAlias: 'lab',
    tailscale: true,
  );

  Future<List<String>?> noPrompts(KeyboardInteractiveRequest request) async => null;
  Future<String?> noPassphrase(KeyPassphraseRequest request) async => null;

  group('rows', () {
    test('an SSH machine survives a round trip through its rows, jumps in dial order', () {
      final jumps = machineJumpRows(machine).reversed;
      final read = machineFromRows(machineRow(machine), jumps) as SshMachine;

      expect(read.name, 'lab');
      expect(read.createdAt, created);
      expect(read.updatedAt, updated);
      expect(read.sshConfigAlias, 'lab');
      expect(read.tailscale, isTrue);
      expect(
        [for (final hop in read.hops) (hop.id, hop.label, hop.auth, hop.keyId)],
        [
          ('jump-a', 'ops@bastion.example.com', AuthMethod.key, 'key-a'),
          ('jump-b', 'tunnel@relay:2200', AuthMethod.agent, null),
          ('target', 'dev@localhost:2222', AuthMethod.password, null),
        ],
      );
    });

    test('jump rows carry their position in the chain', () {
      expect(
        [for (final row in machineJumpRows(machine)) (row.id, row.position, row.machineId)],
        [('jump-a', 0, 'target'), ('jump-b', 1, 'target')],
      );
    });

    test('this computer has no SSH columns and no jumps', () {
      final local = LocalMachine(id: 'me', name: 'Mac', createdAt: created, updatedAt: updated);
      final row = machineRow(local);

      expect((row.kind, row.host, row.user, row.auth), (MachineKind.local, null, null, null));
      expect(machineJumpRows(local), isEmpty);
      expect(machineFromRows(row, const []), isA<LocalMachine>());
    });

    test('an SSH row without a host is rejected', () {
      final row = machineRow(machine).copyWith(host: const Value(null));

      expect(() => machineFromRows(row, const []), throwsFormatException);
    });
  });

  group('dial plan', () {
    const secrets = ConnectionSecrets(
      keys: {'key-a': StoredPrivateKey('PEM-A', passphrase: 'pass-a')},
      keyNames: {'key-a': 'Laptop'},
      passwords: {'target': 'hunter2'},
    );

    test('every hop gets its own credentials, jumps first', () {
      final plan = sshTargetFor(machine, secrets, keyboardInteractive: noPrompts, passphrase: noPassphrase);

      expect(
        [for (final hop in plan.hops) hop.label],
        ['ops@bastion.example.com', 'tunnel@relay:2200', 'dev@localhost:2222'],
      );
      final key = plan.jumps[0].auth as SshKeyAuth;
      expect((key.privateKeyPem, key.passphrase, key.name), ('PEM-A', 'pass-a', 'Laptop'));
      expect((plan.target.auth as SshPasswordAuth).password, 'hunter2');
    });

    test('an imported target reads ~/.ssh/config through its alias; jumps and typed-in hosts through their host', () {
      SshTarget plan(String? alias) => sshTargetFor(
        SshMachine(
          id: 'm',
          name: 'm',
          createdAt: created,
          updatedAt: updated,
          target: const SshEndpoint(id: 'm', host: 'build.example.com', user: 'me', auth: AuthMethod.agent),
          jumps: const [SshEndpoint(id: 'j', host: 'gate', user: 'me', auth: AuthMethod.agent)],
          sshConfigAlias: alias,
        ),
        secrets,
        keyboardInteractive: noPrompts,
        passphrase: noPassphrase,
      );
      String? alias(SshHop hop) => (hop.auth as SshConfigAuth).alias;

      expect([for (final hop in plan('imported').hops) alias(hop)], [null, 'imported']);
      expect(alias(plan(null).target), isNull);
    });

    test('none and keyboard-interactive auth need no stored secret', () {
      final tailnet = SshMachine(
        id: 'ts',
        name: 'pi',
        createdAt: created,
        updatedAt: updated,
        target: const SshEndpoint(id: 'ts', host: 'pi.tailnet.ts.net', user: 'pi', auth: AuthMethod.none),
        jumps: const [SshEndpoint(id: 'otp', host: 'gate', user: 'me', auth: AuthMethod.keyboardInteractive)],
      );

      final plan = sshTargetFor(
        tailnet,
        const ConnectionSecrets(),
        keyboardInteractive: noPrompts,
        passphrase: noPassphrase,
      );

      expect(plan.target.auth, isA<SshNoneAuth>());
      expect((plan.jumps.single.auth as SshKeyboardInteractiveAuth).respond, same(noPrompts));
    });

    test('a hop without its secret names the hop and the missing credential', () {
      Matcher missing(String endpointId, CredentialProblem problem) => isA<MissingCredential>()
          .having((e) => e.endpoint.id, 'endpoint', endpointId)
          .having((e) => e.problem, 'problem', problem);

      expect(
        () => sshTargetFor(
          machine,
          const ConnectionSecrets(passwords: {'target': 'x'}),
          keyboardInteractive: noPrompts,
          passphrase: noPassphrase,
        ),
        throwsA(missing('jump-a', CredentialProblem.keyMissing)),
      );
      expect(
        () => sshTargetFor(
          machine,
          const ConnectionSecrets(keys: {'key-a': StoredPrivateKey('PEM-A')}),
          keyboardInteractive: noPrompts,
          passphrase: noPassphrase,
        ),
        throwsA(missing('target', CredentialProblem.passwordMissing)),
      );

      final keyless = SshMachine(
        id: 'k',
        name: 'k',
        createdAt: created,
        updatedAt: updated,
        target: const SshEndpoint(id: 'k', host: 'h', user: 'u', auth: AuthMethod.key),
      );
      expect(
        () => sshTargetFor(keyless, secrets, keyboardInteractive: noPrompts, passphrase: noPassphrase),
        throwsA(missing('k', CredentialProblem.noKeySelected)),
      );
    });
  });
}
