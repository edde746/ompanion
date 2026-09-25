import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_app/database/app_database.dart';
import 'package:omp_app/models/machine.dart';
import 'package:omp_app/models/machine_export.dart';
import 'package:omp_core/ssh.dart';

void main() {
  final now = DateTime.utc(2026, 9, 25);
  final hostKey = generateEd25519Key().publicKey;
  final jumpKey = generateEd25519Key().publicKey;

  final laptopKey = SshKeyRow(
    id: 'laptop-key',
    name: 'laptop',
    type: 'ssh-ed25519',
    publicKey: 'ssh-ed25519 AAAA laptop',
    fingerprint: 'SHA256:laptop',
    createdAt: now,
  );

  final machine = SshMachine(
    id: 'm',
    name: 'build',
    createdAt: now,
    updatedAt: now,
    target: const SshEndpoint(id: 'm', host: 'build.internal', user: 'ci', auth: AuthMethod.key, keyId: 'laptop-key'),
    jumps: const [SshEndpoint(id: 'j', host: 'bastion', port: 2222, user: 'ops', auth: AuthMethod.password)],
    sshConfigAlias: 'build',
  );

  KnownHostRow trusted(String host, int port, SshPublicKey key) => KnownHostRow(
    host: host,
    port: port,
    keyType: key.type,
    keyBlob: base64.encode(key.blob),
    fingerprint: key.fingerprint,
    addedAt: now,
  );

  final otherHost = generateEd25519Key().publicKey;
  final knownHosts = [
    trusted('build.internal', 22, hostKey),
    trusted('bastion', 2222, jumpKey),
    trusted('unrelated', 22, otherHost),
  ];

  String exportJson() => encodeMachineExport(
    exportMachines([machine], keysById: {laptopKey.id: laptopKey}, knownHosts: knownHosts),
  );

  var ids = 0;
  String newId() => 'new-${ids++}';

  setUp(() => ids = 0);

  test('an export carries the route, key fingerprints and host keys of its hops, never key ids', () {
    final json = jsonDecode(exportJson()) as Map<String, Object?>;

    expect(json['format'], machineExportFormat);
    final exported = (json['machines'] as List<Object?>).single as Map<String, Object?>;
    expect(exported['keyFingerprint'], 'SHA256:laptop');
    expect(exportJson(), isNot(contains('laptop-key')));
    final hostKeys = [for (final key in json['hostKeys'] as List<Object?>) (key as Map<String, Object?>)['host']];
    expect(hostKeys, unorderedEquals(['build.internal', 'bastion']));
  });

  test('importing on another device links keys by fingerprint and gives fresh ids', () {
    final imported = importMachines(
      decodeMachineExport(exportJson()),
      existing: const [],
      keyIdsByFingerprint: {'SHA256:laptop': 'phone-copy-of-laptop-key'},
      now: now,
      newId: newId,
    ).single;

    expect(imported.id, 'new-0');
    expect(imported.target.id, imported.id);
    expect(imported.jumps.single.id, 'new-1');
    expect(imported.target.keyId, 'phone-copy-of-laptop-key');
    expect([for (final hop in imported.hops) (hop.label, hop.auth)], [
      ('ops@bastion:2222', AuthMethod.password),
      ('ci@build.internal', AuthMethod.key),
    ]);
    expect(imported.sshConfigAlias, 'build');
  });

  test('a key this device lacks leaves key auth with no key selected', () {
    final imported = importMachines(
      decodeMachineExport(exportJson()),
      existing: const [],
      keyIdsByFingerprint: const {},
      now: now,
      newId: newId,
    ).single;

    expect((imported.target.auth, imported.target.keyId), (AuthMethod.key, null));
  });

  test('a machine whose route already exists is skipped', () {
    final imported = importMachines(
      decodeMachineExport(exportJson()),
      existing: [machine],
      keyIdsByFingerprint: const {},
      now: now,
      newId: newId,
    );

    expect(imported, isEmpty);
  });

  test('imported host keys never replace a key this device already trusts', () {
    final changed = generateEd25519Key().publicKey;
    final rows = importHostKeys(
      decodeMachineExport(exportJson()),
      existing: [trusted('build.internal', 22, changed)],
      now: now,
    );

    expect([for (final row in rows) (row.host, row.port, row.fingerprint)], [('bastion', 2222, jumpKey.fingerprint)]);
  });

  group('rejects', () {
    Map<String, Object?> valid() => jsonDecode(exportJson()) as Map<String, Object?>;

    Map<String, Object?> firstMachine(Map<String, Object?> json) =>
        (json['machines'] as List<Object?>).first as Map<String, Object?>;

    final cases = <String, Map<String, Object?> Function()>{
      'another format': () => valid()..['format'] = 'something-else',
      'a newer version': () => valid()..['version'] = machineExportVersion + 1,
      'an unknown auth method': () {
        final json = valid();
        firstMachine(json)['auth'] = 'telepathy';
        return json;
      },
      'a port out of range': () {
        final json = valid();
        firstMachine(json)['port'] = 70000;
        return json;
      },
      'an empty host': () {
        final json = valid();
        firstMachine(json)['host'] = '';
        return json;
      },
      'a host key that is not base64': () {
        final json = valid();
        ((json['hostKeys'] as List<Object?>).first as Map<String, Object?>)['keyBlob'] = 'not base64!';
        return json;
      },
    };
    for (final MapEntry(key: name, value: build) in cases.entries) {
      test(name, () => expect(() => decodeMachineExport(jsonEncode(build())), throwsFormatException));
    }

    test('text that is not JSON', () => expect(() => decodeMachineExport('ssh user@host'), throwsFormatException));
  });
}
