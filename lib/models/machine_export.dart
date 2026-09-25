import 'dart:convert';

import 'package:omp_core/ssh.dart';

import '../database/app_database.dart';
import 'machine.dart';

/// Marks a machine export file; anything else is rejected on import.
const machineExportFormat = 'omp-app/machines';
const machineExportVersion = 1;

/// One hop of an exported machine. A key travels as its fingerprint only; the importing device links its own
/// key with that fingerprint, if it has one.
final class ExportedEndpoint {
  const ExportedEndpoint({
    required this.host,
    required this.port,
    required this.user,
    required this.auth,
    this.keyFingerprint,
  });

  final String host;
  final int port;
  final String user;
  final AuthMethod auth;
  final String? keyFingerprint;
}

final class ExportedMachine {
  const ExportedMachine({
    required this.name,
    required this.target,
    required this.jumps,
    this.sshConfigAlias,
    required this.tailscale,
  });

  final String name;
  final ExportedEndpoint target;
  final List<ExportedEndpoint> jumps;
  final String? sshConfigAlias;
  final bool tailscale;
}

final class ExportedHostKey {
  const ExportedHostKey({required this.host, required this.port, required this.keyType, required this.keyBlob});

  final String host;
  final int port;
  final String keyType;

  /// SSH wire-format public key, base64.
  final String keyBlob;
}

/// SSH machines with their jump chains and the trusted host keys of every hop. Never secrets: no private
/// keys, passphrases or passwords.
final class MachineExport {
  const MachineExport({required this.machines, required this.hostKeys});

  final List<ExportedMachine> machines;
  final List<ExportedHostKey> hostKeys;
}

MachineExport exportMachines(
  Iterable<SshMachine> machines, {
  required Map<String, SshKeyRow> keysById,
  required Iterable<KnownHostRow> knownHosts,
}) {
  ExportedEndpoint endpoint(SshEndpoint e) => ExportedEndpoint(
    host: e.host,
    port: e.port,
    user: e.user,
    auth: e.auth,
    keyFingerprint: e.auth == AuthMethod.key ? keysById[e.keyId]?.fingerprint : null,
  );
  final exported = [
    for (final m in machines)
      ExportedMachine(
        name: m.name,
        target: endpoint(m.target),
        jumps: [for (final jump in m.jumps) endpoint(jump)],
        sshConfigAlias: m.sshConfigAlias,
        tailscale: m.tailscale,
      ),
  ];
  final hops = {
    for (final m in machines)
      for (final hop in m.hops) (hop.host, hop.port),
  };
  return MachineExport(
    machines: exported,
    hostKeys: [
      for (final row in knownHosts)
        if (hops.contains((row.host, row.port)))
          ExportedHostKey(host: row.host, port: row.port, keyType: row.keyType, keyBlob: row.keyBlob),
    ],
  );
}

String encodeMachineExport(MachineExport export) {
  Map<String, Object?> endpoint(ExportedEndpoint e) => {
    'host': e.host,
    'port': e.port,
    'user': e.user,
    'auth': e.auth.name,
    if (e.keyFingerprint != null) 'keyFingerprint': e.keyFingerprint,
  };
  return const JsonEncoder.withIndent('  ').convert({
    'format': machineExportFormat,
    'version': machineExportVersion,
    'machines': [
      for (final m in export.machines)
        {
          'name': m.name,
          ...endpoint(m.target),
          'jumps': [for (final jump in m.jumps) endpoint(jump)],
          if (m.sshConfigAlias != null) 'sshConfigAlias': m.sshConfigAlias,
          'tailscale': m.tailscale,
        },
    ],
    'hostKeys': [
      for (final key in export.hostKeys)
        {'host': key.host, 'port': key.port, 'keyType': key.keyType, 'keyBlob': key.keyBlob},
    ],
  });
}

/// Throws [FormatException] for anything that is not a version-1 machine export.
MachineExport decodeMachineExport(String text) {
  final root = _object(jsonDecode(text), 'export');
  if (root['format'] != machineExportFormat) throw const FormatException('not an omp-app machine export');
  if (root['version'] != machineExportVersion) {
    throw FormatException('unsupported machine export version ${root['version']}');
  }
  return MachineExport(
    machines: [for (final item in _list(root['machines'], 'machines')) _machine(_object(item, 'machine'))],
    hostKeys: [for (final item in _list(root['hostKeys'], 'hostKeys')) _hostKey(_object(item, 'host key'))],
  );
}

/// New machines for this device from [export], skipping any whose hop chain matches one in [existing].
///
/// Machines get fresh ids. A key is linked when this device has a key with the exported fingerprint;
/// otherwise the hop keeps key auth with no key selected, and the user picks one before connecting.
List<SshMachine> importMachines(
  MachineExport export, {
  required Iterable<SshMachine> existing,
  required Map<String, String> keyIdsByFingerprint,
  required DateTime now,
  required String Function() newId,
}) {
  final routes = {for (final m in existing) _route(m.hops.map((h) => (h.host, h.port, h.user)))};
  final machines = <SshMachine>[];
  for (final m in export.machines) {
    final route = _route([...m.jumps, m.target].map((h) => (h.host, h.port, h.user)));
    if (!routes.add(route)) continue;
    SshEndpoint endpoint(ExportedEndpoint e, String id) => SshEndpoint(
      id: id,
      host: e.host,
      port: e.port,
      user: e.user,
      auth: e.auth,
      keyId: e.auth == AuthMethod.key ? keyIdsByFingerprint[e.keyFingerprint] : null,
    );
    final id = newId();
    machines.add(
      SshMachine(
        id: id,
        name: m.name,
        createdAt: now,
        updatedAt: now,
        target: endpoint(m.target, id),
        jumps: [for (final jump in m.jumps) endpoint(jump, newId())],
        sshConfigAlias: m.sshConfigAlias,
        tailscale: m.tailscale,
      ),
    );
  }
  return machines;
}

/// Exported host keys of one host and port that would change what this device trusts. They are imported only when
/// the user confirms this host.
final class HostKeyImportChange {
  const HostKeyImportChange({required this.host, required this.port, required this.trusted, required this.imported});

  final String host;
  final int port;

  /// What this device trusts for the host and port now; empty when nothing.
  final List<KnownHostRow> trusted;

  /// The export's keys for the host and port that this device does not trust.
  final List<KnownHostRow> imported;
}

/// The host keys of an import. [trusted] are added without asking: keys of hops of machines the import adds
/// ([added]), for host and port pairs this device has no key of any type for. Every other exported key this device
/// does not trust yet is in [changes], one per host and port, for the user to confirm; an import never changes
/// local trust on its own.
typedef HostKeyImport = ({List<KnownHostRow> trusted, List<HostKeyImportChange> changes});

HostKeyImport importHostKeys(
  MachineExport export, {
  required Iterable<SshMachine> added,
  required Iterable<KnownHostRow> existing,
  required DateTime now,
}) {
  final addedHops = {
    for (final machine in added)
      for (final hop in machine.hops) (hop.host, hop.port),
  };
  final recorded = <(String, int), List<KnownHostRow>>{};
  for (final row in existing) {
    (recorded[(row.host, row.port)] ??= []).add(row);
  }
  final seen = <(String, int, String)>{};
  final trusted = <KnownHostRow>[];
  final pending = <(String, int), List<KnownHostRow>>{};
  for (final key in export.hostKeys) {
    if (!seen.add((key.host, key.port, key.keyType))) continue;
    final here = recorded[(key.host, key.port)] ?? const <KnownHostRow>[];
    if (here.any((row) => row.keyType == key.keyType && row.keyBlob == key.keyBlob)) continue;
    final row = KnownHostRow(
      host: key.host,
      port: key.port,
      keyType: key.keyType,
      keyBlob: key.keyBlob,
      fingerprint: sha256Fingerprint(base64.decode(key.keyBlob)),
      addedAt: now,
    );
    if (here.isEmpty && addedHops.contains((key.host, key.port))) {
      trusted.add(row);
    } else {
      (pending[(key.host, key.port)] ??= []).add(row);
    }
  }
  return (
    trusted: trusted,
    changes: [
      for (final MapEntry(key: (host, port), value: imported) in pending.entries)
        HostKeyImportChange(host: host, port: port, trusted: recorded[(host, port)] ?? const [], imported: imported),
    ],
  );
}

String _route(Iterable<(String, int, String)> hops) => [for (final (host, port, user) in hops) '$user@$host:$port'].join(' > ');

ExportedMachine _machine(Map<String, Object?> json) => ExportedMachine(
  name: _string(json, 'name'),
  target: _endpoint(json),
  jumps: [for (final jump in _list(json['jumps'], 'jumps')) _endpoint(_object(jump, 'jump'))],
  sshConfigAlias: _optionalString(json, 'sshConfigAlias'),
  tailscale: json['tailscale'] == true,
);

ExportedHostKey _hostKey(Map<String, Object?> json) {
  final blob = _string(json, 'keyBlob');
  // Rejects a blob that is not base64 before it reaches the trust store.
  base64.decode(blob);
  return ExportedHostKey(host: _string(json, 'host'), port: _port(json), keyType: _string(json, 'keyType'), keyBlob: blob);
}

ExportedEndpoint _endpoint(Map<String, Object?> json) {
  final authName = _string(json, 'auth');
  final auth = AuthMethod.values.asNameMap()[authName];
  if (auth == null) throw FormatException('unknown auth method "$authName"');
  return ExportedEndpoint(
    host: _string(json, 'host'),
    port: _port(json),
    user: _string(json, 'user'),
    auth: auth,
    keyFingerprint: _optionalString(json, 'keyFingerprint'),
  );
}

Map<String, Object?> _object(Object? json, String what) {
  if (json is Map<String, Object?>) return json;
  throw FormatException('$what: expected an object');
}

List<Object?> _list(Object? json, String what) {
  if (json is List<Object?>) return json;
  throw FormatException('$what: expected a list');
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('"$key" must be a non-empty string');
}

String? _optionalString(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('"$key" must be a string');
}

int _port(Map<String, Object?> json) {
  final value = json['port'];
  if (value is int && value > 0 && value < 65536) return value;
  throw FormatException('invalid port $value');
}
