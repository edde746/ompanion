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

  group('host keys', () {
    final ecdsa = SshPublicKey.parse(
      'ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBFHCjHHkyHlZM7oIFdfJJ9SEHnTxNIdCaR87+lpDDrgJpK6FgI9mKZL4CPScjRW1Oz0t3HzAcKIENX2kagJKp0Y=',
    );

    /// The export with [keys] appended to its host keys, as a crafted file could list them.
    MachineExport withKeys(List<(String, int, SshPublicKey)> keys) {
      final json = jsonDecode(exportJson()) as Map<String, Object?>;
      (json['hostKeys'] as List<Object?>).addAll([
        for (final (host, port, key) in keys)
          {'host': host, 'port': port, 'keyType': key.type, 'keyBlob': base64.encode(key.blob)},
      ]);
      return decodeMachineExport(jsonEncode(json));
    }

    List<SshMachine> added(MachineExport export, {List<SshMachine> existing = const []}) =>
        importMachines(export, existing: existing, keyIdsByFingerprint: const {}, now: now, newId: newId);

    List<(String, int, String)> triples(Iterable<KnownHostRow> rows) => [
      for (final row in rows) (row.host, row.port, row.fingerprint),
    ];

    test('keys of hops of machines the import adds are trusted when this device has none for them', () {
      final export = decodeMachineExport(exportJson());
      final keys = importHostKeys(export, added: added(export), existing: const [], now: now);

      expect(
        triples(keys.trusted),
        unorderedEquals([('build.internal', 22, hostKey.fingerprint), ('bastion', 2222, jumpKey.fingerprint)]),
      );
      expect(keys.changes, isEmpty);
    });

    test('a key of another type for a host this device trusts waits for confirmation as a change', () {
      final export = withKeys([('build.internal', 22, ecdsa)]);
      final keys = importHostKeys(export, added: added(export), existing: [trusted('build.internal', 22, hostKey)], now: now);

      expect(triples(keys.trusted), [('bastion', 2222, jumpKey.fingerprint)]);
      final change = keys.changes.single;
      expect((change.host, change.port), ('build.internal', 22));
      expect(triples(change.trusted), [('build.internal', 22, hostKey.fingerprint)]);
      expect(triples(change.imported), [('build.internal', 22, ecdsa.fingerprint)]);
    });

    test('a different key of the same type waits for confirmation instead of replacing the trusted one', () {
      final changed = generateEd25519Key().publicKey;
      final export = decodeMachineExport(exportJson());
      final keys = importHostKeys(export, added: added(export), existing: [trusted('build.internal', 22, changed)], now: now);

      expect(triples(keys.trusted), [('bastion', 2222, jumpKey.fingerprint)]);
      expect(triples(keys.changes.single.trusted), [('build.internal', 22, changed.fingerprint)]);
      expect(triples(keys.changes.single.imported), [('build.internal', 22, hostKey.fingerprint)]);
    });

    test('keys of hosts no added machine uses wait for confirmation, one change per host', () {
      // The machine is here already, so the import adds nothing; a crafted file can also name unrelated hosts.
      final export = withKeys([('unrelated', 22, otherHost), ('unrelated', 22, ecdsa)]);
      final keys = importHostKeys(export, added: added(export, existing: [machine]), existing: const [], now: now);

      expect(keys.trusted, isEmpty);
      expect(
        [for (final change in keys.changes) (change.host, change.port, change.trusted.length, change.imported.length)],
        [('build.internal', 22, 0, 1), ('bastion', 2222, 0, 1), ('unrelated', 22, 0, 2)],
      );
    });

    test('keys this device already trusts are neither added nor asked about', () {
      final export = decodeMachineExport(exportJson());
      final keys = importHostKeys(
        export,
        added: added(export),
        existing: [trusted('build.internal', 22, hostKey), trusted('bastion', 2222, jumpKey)],
        now: now,
      );

      expect(keys.trusted, isEmpty);
      expect(keys.changes, isEmpty);
    });
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
