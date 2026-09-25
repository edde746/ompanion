import 'package:drift/drift.dart';

enum MachineKind { local, ssh }

/// How one SSH hop authenticates. Secrets (private keys, passwords) live in secure storage, never here.
enum AuthMethod { key, password, agent, none, keyboardInteractive }

/// One row per machine. SSH columns are null for [MachineKind.local].
@DataClassName('MachineRow')
class Machines extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => textEnum<MachineKind>()();
  TextColumn get host => text().nullable()();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get user => text().nullable()();
  TextColumn get auth => textEnum<AuthMethod>().nullable()();
  TextColumn get keyId => text().nullable().references(SshKeys, #id, onDelete: KeyAction.setNull)();
  TextColumn get sshConfigAlias => text().nullable()();
  BoolColumn get tailscale => boolean().withDefault(const Constant(false))();
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Jump hosts of an SSH machine, dialed in [position] order before the target.
@DataClassName('MachineJumpRow')
class MachineJumps extends Table {
  TextColumn get id => text()();
  TextColumn get machineId => text().references(Machines, #id, onDelete: KeyAction.cascade)();
  IntColumn get position => integer()();
  TextColumn get host => text()();
  IntColumn get port => integer().withDefault(const Constant(22))();
  TextColumn get user => text()();
  TextColumn get auth => textEnum<AuthMethod>()();
  TextColumn get keyId => text().nullable().references(SshKeys, #id, onDelete: KeyAction.setNull)();

  @override
  Set<Column<Object>> get primaryKey => {id};

  @override
  List<Set<Column<Object>>> get uniqueKeys => [
    {machineId, position},
  ];
}

/// Public half of an SSH key. The private key is in secure storage under the same id.
@DataClassName('SshKeyRow')
class SshKeys extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get type => text()();

  /// `authorized_keys` line: `<type> <base64> [comment]`.
  TextColumn get publicKey => text()();

  /// OpenSSH form: `SHA256:` plus unpadded base64.
  TextColumn get fingerprint => text()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

/// Trusted host keys, one per host, port and key type.
@DataClassName('KnownHostRow')
class KnownHosts extends Table {
  TextColumn get host => text()();
  IntColumn get port => integer()();
  TextColumn get keyType => text()();

  /// SSH wire-format public key, base64.
  TextColumn get keyBlob => text()();
  TextColumn get fingerprint => text()();
  DateTimeColumn get addedAt => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {host, port, keyType};
}

/// App settings as JSON values, read and written through typed `Pref`s.
@DataClassName('SettingRow')
class Settings extends Table {
  TextColumn get key => text()();
  TextColumn get value => text()();

  @override
  Set<Column<Object>> get primaryKey => {key};
}

/// Per session file, the file modification time up to which the user has read it. The time is the machine's
/// (`SessionSummary.modified`), so it compares with later listings without clock skew.
@DataClassName('ReadMarkerRow')
class ReadMarkers extends Table {
  TextColumn get machineId => text().references(Machines, #id, onDelete: KeyAction.cascade)();

  /// Host-native path of the session file.
  TextColumn get path => text()();
  DateTimeColumn get seenModified => dateTime()();

  @override
  Set<Column<Object>> get primaryKey => {machineId, path};
}
