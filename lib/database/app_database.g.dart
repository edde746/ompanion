// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $SshKeysTable extends SshKeys with TableInfo<$SshKeysTable, SshKeyRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SshKeysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _publicKeyMeta = const VerificationMeta(
    'publicKey',
  );
  @override
  late final GeneratedColumn<String> publicKey = GeneratedColumn<String>(
    'public_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    type,
    publicKey,
    fingerprint,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'ssh_keys';
  @override
  VerificationContext validateIntegrity(
    Insertable<SshKeyRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('public_key')) {
      context.handle(
        _publicKeyMeta,
        publicKey.isAcceptableOrUnknown(data['public_key']!, _publicKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_publicKeyMeta);
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SshKeyRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SshKeyRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      publicKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}public_key'],
      )!,
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $SshKeysTable createAlias(String alias) {
    return $SshKeysTable(attachedDatabase, alias);
  }
}

class SshKeyRow extends DataClass implements Insertable<SshKeyRow> {
  final String id;
  final String name;
  final String type;

  /// `authorized_keys` line: `<type> <base64> [comment]`.
  final String publicKey;

  /// OpenSSH form: `SHA256:` plus unpadded base64.
  final String fingerprint;
  final DateTime createdAt;
  const SshKeyRow({
    required this.id,
    required this.name,
    required this.type,
    required this.publicKey,
    required this.fingerprint,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    map['type'] = Variable<String>(type);
    map['public_key'] = Variable<String>(publicKey);
    map['fingerprint'] = Variable<String>(fingerprint);
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  SshKeysCompanion toCompanion(bool nullToAbsent) {
    return SshKeysCompanion(
      id: Value(id),
      name: Value(name),
      type: Value(type),
      publicKey: Value(publicKey),
      fingerprint: Value(fingerprint),
      createdAt: Value(createdAt),
    );
  }

  factory SshKeyRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SshKeyRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      type: serializer.fromJson<String>(json['type']),
      publicKey: serializer.fromJson<String>(json['publicKey']),
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'type': serializer.toJson<String>(type),
      'publicKey': serializer.toJson<String>(publicKey),
      'fingerprint': serializer.toJson<String>(fingerprint),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  SshKeyRow copyWith({
    String? id,
    String? name,
    String? type,
    String? publicKey,
    String? fingerprint,
    DateTime? createdAt,
  }) => SshKeyRow(
    id: id ?? this.id,
    name: name ?? this.name,
    type: type ?? this.type,
    publicKey: publicKey ?? this.publicKey,
    fingerprint: fingerprint ?? this.fingerprint,
    createdAt: createdAt ?? this.createdAt,
  );
  SshKeyRow copyWithCompanion(SshKeysCompanion data) {
    return SshKeyRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      type: data.type.present ? data.type.value : this.type,
      publicKey: data.publicKey.present ? data.publicKey.value : this.publicKey,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SshKeyRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('publicKey: $publicKey, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, name, type, publicKey, fingerprint, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SshKeyRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.type == this.type &&
          other.publicKey == this.publicKey &&
          other.fingerprint == this.fingerprint &&
          other.createdAt == this.createdAt);
}

class SshKeysCompanion extends UpdateCompanion<SshKeyRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String> type;
  final Value<String> publicKey;
  final Value<String> fingerprint;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const SshKeysCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.type = const Value.absent(),
    this.publicKey = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SshKeysCompanion.insert({
    required String id,
    required String name,
    required String type,
    required String publicKey,
    required String fingerprint,
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       type = Value(type),
       publicKey = Value(publicKey),
       fingerprint = Value(fingerprint),
       createdAt = Value(createdAt);
  static Insertable<SshKeyRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? type,
    Expression<String>? publicKey,
    Expression<String>? fingerprint,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (type != null) 'type': type,
      if (publicKey != null) 'public_key': publicKey,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SshKeysCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String>? type,
    Value<String>? publicKey,
    Value<String>? fingerprint,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return SshKeysCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      publicKey: publicKey ?? this.publicKey,
      fingerprint: fingerprint ?? this.fingerprint,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (publicKey.present) {
      map['public_key'] = Variable<String>(publicKey.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SshKeysCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('type: $type, ')
          ..write('publicKey: $publicKey, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MachinesTable extends Machines
    with TableInfo<$MachinesTable, MachineRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MachinesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<MachineKind, String> kind =
      GeneratedColumn<String>(
        'kind',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<MachineKind>($MachinesTable.$converterkind);
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
    'host',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(22),
  );
  static const VerificationMeta _userMeta = const VerificationMeta('user');
  @override
  late final GeneratedColumn<String> user = GeneratedColumn<String>(
    'user',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<AuthMethod?, String> auth =
      GeneratedColumn<String>(
        'auth',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      ).withConverter<AuthMethod?>($MachinesTable.$converterauthn);
  static const VerificationMeta _keyIdMeta = const VerificationMeta('keyId');
  @override
  late final GeneratedColumn<String> keyId = GeneratedColumn<String>(
    'key_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES ssh_keys (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _sshConfigAliasMeta = const VerificationMeta(
    'sshConfigAlias',
  );
  @override
  late final GeneratedColumn<String> sshConfigAlias = GeneratedColumn<String>(
    'ssh_config_alias',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tailscaleMeta = const VerificationMeta(
    'tailscale',
  );
  @override
  late final GeneratedColumn<bool> tailscale = GeneratedColumn<bool>(
    'tailscale',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("tailscale" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    kind,
    host,
    port,
    user,
    auth,
    keyId,
    sshConfigAlias,
    tailscale,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'machines';
  @override
  VerificationContext validateIntegrity(
    Insertable<MachineRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('host')) {
      context.handle(
        _hostMeta,
        host.isAcceptableOrUnknown(data['host']!, _hostMeta),
      );
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('user')) {
      context.handle(
        _userMeta,
        user.isAcceptableOrUnknown(data['user']!, _userMeta),
      );
    }
    if (data.containsKey('key_id')) {
      context.handle(
        _keyIdMeta,
        keyId.isAcceptableOrUnknown(data['key_id']!, _keyIdMeta),
      );
    }
    if (data.containsKey('ssh_config_alias')) {
      context.handle(
        _sshConfigAliasMeta,
        sshConfigAlias.isAcceptableOrUnknown(
          data['ssh_config_alias']!,
          _sshConfigAliasMeta,
        ),
      );
    }
    if (data.containsKey('tailscale')) {
      context.handle(
        _tailscaleMeta,
        tailscale.isAcceptableOrUnknown(data['tailscale']!, _tailscaleMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MachineRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MachineRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      kind: $MachinesTable.$converterkind.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}kind'],
        )!,
      ),
      host: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host'],
      ),
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      user: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user'],
      ),
      auth: $MachinesTable.$converterauthn.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}auth'],
        ),
      ),
      keyId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key_id'],
      ),
      sshConfigAlias: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}ssh_config_alias'],
      ),
      tailscale: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}tailscale'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $MachinesTable createAlias(String alias) {
    return $MachinesTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<MachineKind, String, String> $converterkind =
      const EnumNameConverter<MachineKind>(MachineKind.values);
  static JsonTypeConverter2<AuthMethod, String, String> $converterauth =
      const EnumNameConverter<AuthMethod>(AuthMethod.values);
  static JsonTypeConverter2<AuthMethod?, String?, String?> $converterauthn =
      JsonTypeConverter2.asNullable($converterauth);
}

class MachineRow extends DataClass implements Insertable<MachineRow> {
  final String id;
  final String name;
  final MachineKind kind;
  final String? host;
  final int port;
  final String? user;
  final AuthMethod? auth;
  final String? keyId;
  final String? sshConfigAlias;
  final bool tailscale;
  final DateTime createdAt;
  final DateTime updatedAt;
  const MachineRow({
    required this.id,
    required this.name,
    required this.kind,
    this.host,
    required this.port,
    this.user,
    this.auth,
    this.keyId,
    this.sshConfigAlias,
    required this.tailscale,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    {
      map['kind'] = Variable<String>($MachinesTable.$converterkind.toSql(kind));
    }
    if (!nullToAbsent || host != null) {
      map['host'] = Variable<String>(host);
    }
    map['port'] = Variable<int>(port);
    if (!nullToAbsent || user != null) {
      map['user'] = Variable<String>(user);
    }
    if (!nullToAbsent || auth != null) {
      map['auth'] = Variable<String>(
        $MachinesTable.$converterauthn.toSql(auth),
      );
    }
    if (!nullToAbsent || keyId != null) {
      map['key_id'] = Variable<String>(keyId);
    }
    if (!nullToAbsent || sshConfigAlias != null) {
      map['ssh_config_alias'] = Variable<String>(sshConfigAlias);
    }
    map['tailscale'] = Variable<bool>(tailscale);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    return map;
  }

  MachinesCompanion toCompanion(bool nullToAbsent) {
    return MachinesCompanion(
      id: Value(id),
      name: Value(name),
      kind: Value(kind),
      host: host == null && nullToAbsent ? const Value.absent() : Value(host),
      port: Value(port),
      user: user == null && nullToAbsent ? const Value.absent() : Value(user),
      auth: auth == null && nullToAbsent ? const Value.absent() : Value(auth),
      keyId: keyId == null && nullToAbsent
          ? const Value.absent()
          : Value(keyId),
      sshConfigAlias: sshConfigAlias == null && nullToAbsent
          ? const Value.absent()
          : Value(sshConfigAlias),
      tailscale: Value(tailscale),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory MachineRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MachineRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      kind: $MachinesTable.$converterkind.fromJson(
        serializer.fromJson<String>(json['kind']),
      ),
      host: serializer.fromJson<String?>(json['host']),
      port: serializer.fromJson<int>(json['port']),
      user: serializer.fromJson<String?>(json['user']),
      auth: $MachinesTable.$converterauthn.fromJson(
        serializer.fromJson<String?>(json['auth']),
      ),
      keyId: serializer.fromJson<String?>(json['keyId']),
      sshConfigAlias: serializer.fromJson<String?>(json['sshConfigAlias']),
      tailscale: serializer.fromJson<bool>(json['tailscale']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'kind': serializer.toJson<String>(
        $MachinesTable.$converterkind.toJson(kind),
      ),
      'host': serializer.toJson<String?>(host),
      'port': serializer.toJson<int>(port),
      'user': serializer.toJson<String?>(user),
      'auth': serializer.toJson<String?>(
        $MachinesTable.$converterauthn.toJson(auth),
      ),
      'keyId': serializer.toJson<String?>(keyId),
      'sshConfigAlias': serializer.toJson<String?>(sshConfigAlias),
      'tailscale': serializer.toJson<bool>(tailscale),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
    };
  }

  MachineRow copyWith({
    String? id,
    String? name,
    MachineKind? kind,
    Value<String?> host = const Value.absent(),
    int? port,
    Value<String?> user = const Value.absent(),
    Value<AuthMethod?> auth = const Value.absent(),
    Value<String?> keyId = const Value.absent(),
    Value<String?> sshConfigAlias = const Value.absent(),
    bool? tailscale,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) => MachineRow(
    id: id ?? this.id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    host: host.present ? host.value : this.host,
    port: port ?? this.port,
    user: user.present ? user.value : this.user,
    auth: auth.present ? auth.value : this.auth,
    keyId: keyId.present ? keyId.value : this.keyId,
    sshConfigAlias: sshConfigAlias.present
        ? sshConfigAlias.value
        : this.sshConfigAlias,
    tailscale: tailscale ?? this.tailscale,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  MachineRow copyWithCompanion(MachinesCompanion data) {
    return MachineRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      kind: data.kind.present ? data.kind.value : this.kind,
      host: data.host.present ? data.host.value : this.host,
      port: data.port.present ? data.port.value : this.port,
      user: data.user.present ? data.user.value : this.user,
      auth: data.auth.present ? data.auth.value : this.auth,
      keyId: data.keyId.present ? data.keyId.value : this.keyId,
      sshConfigAlias: data.sshConfigAlias.present
          ? data.sshConfigAlias.value
          : this.sshConfigAlias,
      tailscale: data.tailscale.present ? data.tailscale.value : this.tailscale,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MachineRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('user: $user, ')
          ..write('auth: $auth, ')
          ..write('keyId: $keyId, ')
          ..write('sshConfigAlias: $sshConfigAlias, ')
          ..write('tailscale: $tailscale, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    kind,
    host,
    port,
    user,
    auth,
    keyId,
    sshConfigAlias,
    tailscale,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MachineRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.kind == this.kind &&
          other.host == this.host &&
          other.port == this.port &&
          other.user == this.user &&
          other.auth == this.auth &&
          other.keyId == this.keyId &&
          other.sshConfigAlias == this.sshConfigAlias &&
          other.tailscale == this.tailscale &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class MachinesCompanion extends UpdateCompanion<MachineRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<MachineKind> kind;
  final Value<String?> host;
  final Value<int> port;
  final Value<String?> user;
  final Value<AuthMethod?> auth;
  final Value<String?> keyId;
  final Value<String?> sshConfigAlias;
  final Value<bool> tailscale;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<int> rowid;
  const MachinesCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.kind = const Value.absent(),
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.user = const Value.absent(),
    this.auth = const Value.absent(),
    this.keyId = const Value.absent(),
    this.sshConfigAlias = const Value.absent(),
    this.tailscale = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MachinesCompanion.insert({
    required String id,
    required String name,
    required MachineKind kind,
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.user = const Value.absent(),
    this.auth = const Value.absent(),
    this.keyId = const Value.absent(),
    this.sshConfigAlias = const Value.absent(),
    this.tailscale = const Value.absent(),
    required DateTime createdAt,
    required DateTime updatedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       kind = Value(kind),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<MachineRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? kind,
    Expression<String>? host,
    Expression<int>? port,
    Expression<String>? user,
    Expression<String>? auth,
    Expression<String>? keyId,
    Expression<String>? sshConfigAlias,
    Expression<bool>? tailscale,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (kind != null) 'kind': kind,
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (user != null) 'user': user,
      if (auth != null) 'auth': auth,
      if (keyId != null) 'key_id': keyId,
      if (sshConfigAlias != null) 'ssh_config_alias': sshConfigAlias,
      if (tailscale != null) 'tailscale': tailscale,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MachinesCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<MachineKind>? kind,
    Value<String?>? host,
    Value<int>? port,
    Value<String?>? user,
    Value<AuthMethod?>? auth,
    Value<String?>? keyId,
    Value<String?>? sshConfigAlias,
    Value<bool>? tailscale,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<int>? rowid,
  }) {
    return MachinesCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      host: host ?? this.host,
      port: port ?? this.port,
      user: user ?? this.user,
      auth: auth ?? this.auth,
      keyId: keyId ?? this.keyId,
      sshConfigAlias: sshConfigAlias ?? this.sshConfigAlias,
      tailscale: tailscale ?? this.tailscale,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(
        $MachinesTable.$converterkind.toSql(kind.value),
      );
    }
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (user.present) {
      map['user'] = Variable<String>(user.value);
    }
    if (auth.present) {
      map['auth'] = Variable<String>(
        $MachinesTable.$converterauthn.toSql(auth.value),
      );
    }
    if (keyId.present) {
      map['key_id'] = Variable<String>(keyId.value);
    }
    if (sshConfigAlias.present) {
      map['ssh_config_alias'] = Variable<String>(sshConfigAlias.value);
    }
    if (tailscale.present) {
      map['tailscale'] = Variable<bool>(tailscale.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MachinesCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('kind: $kind, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('user: $user, ')
          ..write('auth: $auth, ')
          ..write('keyId: $keyId, ')
          ..write('sshConfigAlias: $sshConfigAlias, ')
          ..write('tailscale: $tailscale, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MachineJumpsTable extends MachineJumps
    with TableInfo<$MachineJumpsTable, MachineJumpRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MachineJumpsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _machineIdMeta = const VerificationMeta(
    'machineId',
  );
  @override
  late final GeneratedColumn<String> machineId = GeneratedColumn<String>(
    'machine_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES machines (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
    'host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(22),
  );
  static const VerificationMeta _userMeta = const VerificationMeta('user');
  @override
  late final GeneratedColumn<String> user = GeneratedColumn<String>(
    'user',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  late final GeneratedColumnWithTypeConverter<AuthMethod, String> auth =
      GeneratedColumn<String>(
        'auth',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      ).withConverter<AuthMethod>($MachineJumpsTable.$converterauth);
  static const VerificationMeta _keyIdMeta = const VerificationMeta('keyId');
  @override
  late final GeneratedColumn<String> keyId = GeneratedColumn<String>(
    'key_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES ssh_keys (id) ON DELETE SET NULL',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    machineId,
    position,
    host,
    port,
    user,
    auth,
    keyId,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'machine_jumps';
  @override
  VerificationContext validateIntegrity(
    Insertable<MachineJumpRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('machine_id')) {
      context.handle(
        _machineIdMeta,
        machineId.isAcceptableOrUnknown(data['machine_id']!, _machineIdMeta),
      );
    } else if (isInserting) {
      context.missing(_machineIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('host')) {
      context.handle(
        _hostMeta,
        host.isAcceptableOrUnknown(data['host']!, _hostMeta),
      );
    } else if (isInserting) {
      context.missing(_hostMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    }
    if (data.containsKey('user')) {
      context.handle(
        _userMeta,
        user.isAcceptableOrUnknown(data['user']!, _userMeta),
      );
    } else if (isInserting) {
      context.missing(_userMeta);
    }
    if (data.containsKey('key_id')) {
      context.handle(
        _keyIdMeta,
        keyId.isAcceptableOrUnknown(data['key_id']!, _keyIdMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  List<Set<GeneratedColumn>> get uniqueKeys => [
    {machineId, position},
  ];
  @override
  MachineJumpRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MachineJumpRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      machineId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}machine_id'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      host: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      user: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user'],
      )!,
      auth: $MachineJumpsTable.$converterauth.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.string,
          data['${effectivePrefix}auth'],
        )!,
      ),
      keyId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key_id'],
      ),
    );
  }

  @override
  $MachineJumpsTable createAlias(String alias) {
    return $MachineJumpsTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<AuthMethod, String, String> $converterauth =
      const EnumNameConverter<AuthMethod>(AuthMethod.values);
}

class MachineJumpRow extends DataClass implements Insertable<MachineJumpRow> {
  final String id;
  final String machineId;
  final int position;
  final String host;
  final int port;
  final String user;
  final AuthMethod auth;
  final String? keyId;
  const MachineJumpRow({
    required this.id,
    required this.machineId,
    required this.position,
    required this.host,
    required this.port,
    required this.user,
    required this.auth,
    this.keyId,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['machine_id'] = Variable<String>(machineId);
    map['position'] = Variable<int>(position);
    map['host'] = Variable<String>(host);
    map['port'] = Variable<int>(port);
    map['user'] = Variable<String>(user);
    {
      map['auth'] = Variable<String>(
        $MachineJumpsTable.$converterauth.toSql(auth),
      );
    }
    if (!nullToAbsent || keyId != null) {
      map['key_id'] = Variable<String>(keyId);
    }
    return map;
  }

  MachineJumpsCompanion toCompanion(bool nullToAbsent) {
    return MachineJumpsCompanion(
      id: Value(id),
      machineId: Value(machineId),
      position: Value(position),
      host: Value(host),
      port: Value(port),
      user: Value(user),
      auth: Value(auth),
      keyId: keyId == null && nullToAbsent
          ? const Value.absent()
          : Value(keyId),
    );
  }

  factory MachineJumpRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MachineJumpRow(
      id: serializer.fromJson<String>(json['id']),
      machineId: serializer.fromJson<String>(json['machineId']),
      position: serializer.fromJson<int>(json['position']),
      host: serializer.fromJson<String>(json['host']),
      port: serializer.fromJson<int>(json['port']),
      user: serializer.fromJson<String>(json['user']),
      auth: $MachineJumpsTable.$converterauth.fromJson(
        serializer.fromJson<String>(json['auth']),
      ),
      keyId: serializer.fromJson<String?>(json['keyId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'machineId': serializer.toJson<String>(machineId),
      'position': serializer.toJson<int>(position),
      'host': serializer.toJson<String>(host),
      'port': serializer.toJson<int>(port),
      'user': serializer.toJson<String>(user),
      'auth': serializer.toJson<String>(
        $MachineJumpsTable.$converterauth.toJson(auth),
      ),
      'keyId': serializer.toJson<String?>(keyId),
    };
  }

  MachineJumpRow copyWith({
    String? id,
    String? machineId,
    int? position,
    String? host,
    int? port,
    String? user,
    AuthMethod? auth,
    Value<String?> keyId = const Value.absent(),
  }) => MachineJumpRow(
    id: id ?? this.id,
    machineId: machineId ?? this.machineId,
    position: position ?? this.position,
    host: host ?? this.host,
    port: port ?? this.port,
    user: user ?? this.user,
    auth: auth ?? this.auth,
    keyId: keyId.present ? keyId.value : this.keyId,
  );
  MachineJumpRow copyWithCompanion(MachineJumpsCompanion data) {
    return MachineJumpRow(
      id: data.id.present ? data.id.value : this.id,
      machineId: data.machineId.present ? data.machineId.value : this.machineId,
      position: data.position.present ? data.position.value : this.position,
      host: data.host.present ? data.host.value : this.host,
      port: data.port.present ? data.port.value : this.port,
      user: data.user.present ? data.user.value : this.user,
      auth: data.auth.present ? data.auth.value : this.auth,
      keyId: data.keyId.present ? data.keyId.value : this.keyId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MachineJumpRow(')
          ..write('id: $id, ')
          ..write('machineId: $machineId, ')
          ..write('position: $position, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('user: $user, ')
          ..write('auth: $auth, ')
          ..write('keyId: $keyId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(id, machineId, position, host, port, user, auth, keyId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MachineJumpRow &&
          other.id == this.id &&
          other.machineId == this.machineId &&
          other.position == this.position &&
          other.host == this.host &&
          other.port == this.port &&
          other.user == this.user &&
          other.auth == this.auth &&
          other.keyId == this.keyId);
}

class MachineJumpsCompanion extends UpdateCompanion<MachineJumpRow> {
  final Value<String> id;
  final Value<String> machineId;
  final Value<int> position;
  final Value<String> host;
  final Value<int> port;
  final Value<String> user;
  final Value<AuthMethod> auth;
  final Value<String?> keyId;
  final Value<int> rowid;
  const MachineJumpsCompanion({
    this.id = const Value.absent(),
    this.machineId = const Value.absent(),
    this.position = const Value.absent(),
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.user = const Value.absent(),
    this.auth = const Value.absent(),
    this.keyId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MachineJumpsCompanion.insert({
    required String id,
    required String machineId,
    required int position,
    required String host,
    this.port = const Value.absent(),
    required String user,
    required AuthMethod auth,
    this.keyId = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       machineId = Value(machineId),
       position = Value(position),
       host = Value(host),
       user = Value(user),
       auth = Value(auth);
  static Insertable<MachineJumpRow> custom({
    Expression<String>? id,
    Expression<String>? machineId,
    Expression<int>? position,
    Expression<String>? host,
    Expression<int>? port,
    Expression<String>? user,
    Expression<String>? auth,
    Expression<String>? keyId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (machineId != null) 'machine_id': machineId,
      if (position != null) 'position': position,
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (user != null) 'user': user,
      if (auth != null) 'auth': auth,
      if (keyId != null) 'key_id': keyId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MachineJumpsCompanion copyWith({
    Value<String>? id,
    Value<String>? machineId,
    Value<int>? position,
    Value<String>? host,
    Value<int>? port,
    Value<String>? user,
    Value<AuthMethod>? auth,
    Value<String?>? keyId,
    Value<int>? rowid,
  }) {
    return MachineJumpsCompanion(
      id: id ?? this.id,
      machineId: machineId ?? this.machineId,
      position: position ?? this.position,
      host: host ?? this.host,
      port: port ?? this.port,
      user: user ?? this.user,
      auth: auth ?? this.auth,
      keyId: keyId ?? this.keyId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (machineId.present) {
      map['machine_id'] = Variable<String>(machineId.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (user.present) {
      map['user'] = Variable<String>(user.value);
    }
    if (auth.present) {
      map['auth'] = Variable<String>(
        $MachineJumpsTable.$converterauth.toSql(auth.value),
      );
    }
    if (keyId.present) {
      map['key_id'] = Variable<String>(keyId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MachineJumpsCompanion(')
          ..write('id: $id, ')
          ..write('machineId: $machineId, ')
          ..write('position: $position, ')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('user: $user, ')
          ..write('auth: $auth, ')
          ..write('keyId: $keyId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KnownHostsTable extends KnownHosts
    with TableInfo<$KnownHostsTable, KnownHostRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KnownHostsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _hostMeta = const VerificationMeta('host');
  @override
  late final GeneratedColumn<String> host = GeneratedColumn<String>(
    'host',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _portMeta = const VerificationMeta('port');
  @override
  late final GeneratedColumn<int> port = GeneratedColumn<int>(
    'port',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyTypeMeta = const VerificationMeta(
    'keyType',
  );
  @override
  late final GeneratedColumn<String> keyType = GeneratedColumn<String>(
    'key_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _keyBlobMeta = const VerificationMeta(
    'keyBlob',
  );
  @override
  late final GeneratedColumn<String> keyBlob = GeneratedColumn<String>(
    'key_blob',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _fingerprintMeta = const VerificationMeta(
    'fingerprint',
  );
  @override
  late final GeneratedColumn<String> fingerprint = GeneratedColumn<String>(
    'fingerprint',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<DateTime> addedAt = GeneratedColumn<DateTime>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    host,
    port,
    keyType,
    keyBlob,
    fingerprint,
    addedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'known_hosts';
  @override
  VerificationContext validateIntegrity(
    Insertable<KnownHostRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('host')) {
      context.handle(
        _hostMeta,
        host.isAcceptableOrUnknown(data['host']!, _hostMeta),
      );
    } else if (isInserting) {
      context.missing(_hostMeta);
    }
    if (data.containsKey('port')) {
      context.handle(
        _portMeta,
        port.isAcceptableOrUnknown(data['port']!, _portMeta),
      );
    } else if (isInserting) {
      context.missing(_portMeta);
    }
    if (data.containsKey('key_type')) {
      context.handle(
        _keyTypeMeta,
        keyType.isAcceptableOrUnknown(data['key_type']!, _keyTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_keyTypeMeta);
    }
    if (data.containsKey('key_blob')) {
      context.handle(
        _keyBlobMeta,
        keyBlob.isAcceptableOrUnknown(data['key_blob']!, _keyBlobMeta),
      );
    } else if (isInserting) {
      context.missing(_keyBlobMeta);
    }
    if (data.containsKey('fingerprint')) {
      context.handle(
        _fingerprintMeta,
        fingerprint.isAcceptableOrUnknown(
          data['fingerprint']!,
          _fingerprintMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_fingerprintMeta);
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {host, port, keyType};
  @override
  KnownHostRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KnownHostRow(
      host: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}host'],
      )!,
      port: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}port'],
      )!,
      keyType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key_type'],
      )!,
      keyBlob: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key_blob'],
      )!,
      fingerprint: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}fingerprint'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}added_at'],
      )!,
    );
  }

  @override
  $KnownHostsTable createAlias(String alias) {
    return $KnownHostsTable(attachedDatabase, alias);
  }
}

class KnownHostRow extends DataClass implements Insertable<KnownHostRow> {
  final String host;
  final int port;
  final String keyType;

  /// SSH wire-format public key, base64.
  final String keyBlob;
  final String fingerprint;
  final DateTime addedAt;
  const KnownHostRow({
    required this.host,
    required this.port,
    required this.keyType,
    required this.keyBlob,
    required this.fingerprint,
    required this.addedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['host'] = Variable<String>(host);
    map['port'] = Variable<int>(port);
    map['key_type'] = Variable<String>(keyType);
    map['key_blob'] = Variable<String>(keyBlob);
    map['fingerprint'] = Variable<String>(fingerprint);
    map['added_at'] = Variable<DateTime>(addedAt);
    return map;
  }

  KnownHostsCompanion toCompanion(bool nullToAbsent) {
    return KnownHostsCompanion(
      host: Value(host),
      port: Value(port),
      keyType: Value(keyType),
      keyBlob: Value(keyBlob),
      fingerprint: Value(fingerprint),
      addedAt: Value(addedAt),
    );
  }

  factory KnownHostRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KnownHostRow(
      host: serializer.fromJson<String>(json['host']),
      port: serializer.fromJson<int>(json['port']),
      keyType: serializer.fromJson<String>(json['keyType']),
      keyBlob: serializer.fromJson<String>(json['keyBlob']),
      fingerprint: serializer.fromJson<String>(json['fingerprint']),
      addedAt: serializer.fromJson<DateTime>(json['addedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'host': serializer.toJson<String>(host),
      'port': serializer.toJson<int>(port),
      'keyType': serializer.toJson<String>(keyType),
      'keyBlob': serializer.toJson<String>(keyBlob),
      'fingerprint': serializer.toJson<String>(fingerprint),
      'addedAt': serializer.toJson<DateTime>(addedAt),
    };
  }

  KnownHostRow copyWith({
    String? host,
    int? port,
    String? keyType,
    String? keyBlob,
    String? fingerprint,
    DateTime? addedAt,
  }) => KnownHostRow(
    host: host ?? this.host,
    port: port ?? this.port,
    keyType: keyType ?? this.keyType,
    keyBlob: keyBlob ?? this.keyBlob,
    fingerprint: fingerprint ?? this.fingerprint,
    addedAt: addedAt ?? this.addedAt,
  );
  KnownHostRow copyWithCompanion(KnownHostsCompanion data) {
    return KnownHostRow(
      host: data.host.present ? data.host.value : this.host,
      port: data.port.present ? data.port.value : this.port,
      keyType: data.keyType.present ? data.keyType.value : this.keyType,
      keyBlob: data.keyBlob.present ? data.keyBlob.value : this.keyBlob,
      fingerprint: data.fingerprint.present
          ? data.fingerprint.value
          : this.fingerprint,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KnownHostRow(')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('keyType: $keyType, ')
          ..write('keyBlob: $keyBlob, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(host, port, keyType, keyBlob, fingerprint, addedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is KnownHostRow &&
          other.host == this.host &&
          other.port == this.port &&
          other.keyType == this.keyType &&
          other.keyBlob == this.keyBlob &&
          other.fingerprint == this.fingerprint &&
          other.addedAt == this.addedAt);
}

class KnownHostsCompanion extends UpdateCompanion<KnownHostRow> {
  final Value<String> host;
  final Value<int> port;
  final Value<String> keyType;
  final Value<String> keyBlob;
  final Value<String> fingerprint;
  final Value<DateTime> addedAt;
  final Value<int> rowid;
  const KnownHostsCompanion({
    this.host = const Value.absent(),
    this.port = const Value.absent(),
    this.keyType = const Value.absent(),
    this.keyBlob = const Value.absent(),
    this.fingerprint = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KnownHostsCompanion.insert({
    required String host,
    required int port,
    required String keyType,
    required String keyBlob,
    required String fingerprint,
    required DateTime addedAt,
    this.rowid = const Value.absent(),
  }) : host = Value(host),
       port = Value(port),
       keyType = Value(keyType),
       keyBlob = Value(keyBlob),
       fingerprint = Value(fingerprint),
       addedAt = Value(addedAt);
  static Insertable<KnownHostRow> custom({
    Expression<String>? host,
    Expression<int>? port,
    Expression<String>? keyType,
    Expression<String>? keyBlob,
    Expression<String>? fingerprint,
    Expression<DateTime>? addedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (host != null) 'host': host,
      if (port != null) 'port': port,
      if (keyType != null) 'key_type': keyType,
      if (keyBlob != null) 'key_blob': keyBlob,
      if (fingerprint != null) 'fingerprint': fingerprint,
      if (addedAt != null) 'added_at': addedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KnownHostsCompanion copyWith({
    Value<String>? host,
    Value<int>? port,
    Value<String>? keyType,
    Value<String>? keyBlob,
    Value<String>? fingerprint,
    Value<DateTime>? addedAt,
    Value<int>? rowid,
  }) {
    return KnownHostsCompanion(
      host: host ?? this.host,
      port: port ?? this.port,
      keyType: keyType ?? this.keyType,
      keyBlob: keyBlob ?? this.keyBlob,
      fingerprint: fingerprint ?? this.fingerprint,
      addedAt: addedAt ?? this.addedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (host.present) {
      map['host'] = Variable<String>(host.value);
    }
    if (port.present) {
      map['port'] = Variable<int>(port.value);
    }
    if (keyType.present) {
      map['key_type'] = Variable<String>(keyType.value);
    }
    if (keyBlob.present) {
      map['key_blob'] = Variable<String>(keyBlob.value);
    }
    if (fingerprint.present) {
      map['fingerprint'] = Variable<String>(fingerprint.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<DateTime>(addedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KnownHostsCompanion(')
          ..write('host: $host, ')
          ..write('port: $port, ')
          ..write('keyType: $keyType, ')
          ..write('keyBlob: $keyBlob, ')
          ..write('fingerprint: $fingerprint, ')
          ..write('addedAt: $addedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $SettingsTable extends Settings
    with TableInfo<$SettingsTable, SettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<SettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  SettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SettingRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $SettingsTable createAlias(String alias) {
    return $SettingsTable(attachedDatabase, alias);
  }
}

class SettingRow extends DataClass implements Insertable<SettingRow> {
  final String key;
  final String value;
  const SettingRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  SettingsCompanion toCompanion(bool nullToAbsent) {
    return SettingsCompanion(key: Value(key), value: Value(value));
  }

  factory SettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SettingRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  SettingRow copyWith({String? key, String? value}) =>
      SettingRow(key: key ?? this.key, value: value ?? this.value);
  SettingRow copyWithCompanion(SettingsCompanion data) {
    return SettingRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SettingRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SettingRow &&
          other.key == this.key &&
          other.value == this.value);
}

class SettingsCompanion extends UpdateCompanion<SettingRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const SettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<SettingRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return SettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ReadMarkersTable extends ReadMarkers
    with TableInfo<$ReadMarkersTable, ReadMarkerRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ReadMarkersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _machineIdMeta = const VerificationMeta(
    'machineId',
  );
  @override
  late final GeneratedColumn<String> machineId = GeneratedColumn<String>(
    'machine_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES machines (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _seenModifiedMeta = const VerificationMeta(
    'seenModified',
  );
  @override
  late final GeneratedColumn<DateTime> seenModified = GeneratedColumn<DateTime>(
    'seen_modified',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [machineId, path, seenModified];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'read_markers';
  @override
  VerificationContext validateIntegrity(
    Insertable<ReadMarkerRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('machine_id')) {
      context.handle(
        _machineIdMeta,
        machineId.isAcceptableOrUnknown(data['machine_id']!, _machineIdMeta),
      );
    } else if (isInserting) {
      context.missing(_machineIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('seen_modified')) {
      context.handle(
        _seenModifiedMeta,
        seenModified.isAcceptableOrUnknown(
          data['seen_modified']!,
          _seenModifiedMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_seenModifiedMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {machineId, path};
  @override
  ReadMarkerRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ReadMarkerRow(
      machineId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}machine_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      seenModified: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}seen_modified'],
      )!,
    );
  }

  @override
  $ReadMarkersTable createAlias(String alias) {
    return $ReadMarkersTable(attachedDatabase, alias);
  }
}

class ReadMarkerRow extends DataClass implements Insertable<ReadMarkerRow> {
  final String machineId;

  /// Host-native path of the session file.
  final String path;
  final DateTime seenModified;
  const ReadMarkerRow({
    required this.machineId,
    required this.path,
    required this.seenModified,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['machine_id'] = Variable<String>(machineId);
    map['path'] = Variable<String>(path);
    map['seen_modified'] = Variable<DateTime>(seenModified);
    return map;
  }

  ReadMarkersCompanion toCompanion(bool nullToAbsent) {
    return ReadMarkersCompanion(
      machineId: Value(machineId),
      path: Value(path),
      seenModified: Value(seenModified),
    );
  }

  factory ReadMarkerRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ReadMarkerRow(
      machineId: serializer.fromJson<String>(json['machineId']),
      path: serializer.fromJson<String>(json['path']),
      seenModified: serializer.fromJson<DateTime>(json['seenModified']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'machineId': serializer.toJson<String>(machineId),
      'path': serializer.toJson<String>(path),
      'seenModified': serializer.toJson<DateTime>(seenModified),
    };
  }

  ReadMarkerRow copyWith({
    String? machineId,
    String? path,
    DateTime? seenModified,
  }) => ReadMarkerRow(
    machineId: machineId ?? this.machineId,
    path: path ?? this.path,
    seenModified: seenModified ?? this.seenModified,
  );
  ReadMarkerRow copyWithCompanion(ReadMarkersCompanion data) {
    return ReadMarkerRow(
      machineId: data.machineId.present ? data.machineId.value : this.machineId,
      path: data.path.present ? data.path.value : this.path,
      seenModified: data.seenModified.present
          ? data.seenModified.value
          : this.seenModified,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ReadMarkerRow(')
          ..write('machineId: $machineId, ')
          ..write('path: $path, ')
          ..write('seenModified: $seenModified')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(machineId, path, seenModified);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ReadMarkerRow &&
          other.machineId == this.machineId &&
          other.path == this.path &&
          other.seenModified == this.seenModified);
}

class ReadMarkersCompanion extends UpdateCompanion<ReadMarkerRow> {
  final Value<String> machineId;
  final Value<String> path;
  final Value<DateTime> seenModified;
  final Value<int> rowid;
  const ReadMarkersCompanion({
    this.machineId = const Value.absent(),
    this.path = const Value.absent(),
    this.seenModified = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ReadMarkersCompanion.insert({
    required String machineId,
    required String path,
    required DateTime seenModified,
    this.rowid = const Value.absent(),
  }) : machineId = Value(machineId),
       path = Value(path),
       seenModified = Value(seenModified);
  static Insertable<ReadMarkerRow> custom({
    Expression<String>? machineId,
    Expression<String>? path,
    Expression<DateTime>? seenModified,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (machineId != null) 'machine_id': machineId,
      if (path != null) 'path': path,
      if (seenModified != null) 'seen_modified': seenModified,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ReadMarkersCompanion copyWith({
    Value<String>? machineId,
    Value<String>? path,
    Value<DateTime>? seenModified,
    Value<int>? rowid,
  }) {
    return ReadMarkersCompanion(
      machineId: machineId ?? this.machineId,
      path: path ?? this.path,
      seenModified: seenModified ?? this.seenModified,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (machineId.present) {
      map['machine_id'] = Variable<String>(machineId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (seenModified.present) {
      map['seen_modified'] = Variable<DateTime>(seenModified.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ReadMarkersCompanion(')
          ..write('machineId: $machineId, ')
          ..write('path: $path, ')
          ..write('seenModified: $seenModified, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PinnedSessionsTable extends PinnedSessions
    with TableInfo<$PinnedSessionsTable, PinnedSessionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PinnedSessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _machineIdMeta = const VerificationMeta(
    'machineId',
  );
  @override
  late final GeneratedColumn<String> machineId = GeneratedColumn<String>(
    'machine_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES machines (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sessionIdMeta = const VerificationMeta(
    'sessionId',
  );
  @override
  late final GeneratedColumn<String> sessionId = GeneratedColumn<String>(
    'session_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cwdMeta = const VerificationMeta('cwd');
  @override
  late final GeneratedColumn<String> cwd = GeneratedColumn<String>(
    'cwd',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _firstMessageMeta = const VerificationMeta(
    'firstMessage',
  );
  @override
  late final GeneratedColumn<String> firstMessage = GeneratedColumn<String>(
    'first_message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pinnedAtMeta = const VerificationMeta(
    'pinnedAt',
  );
  @override
  late final GeneratedColumn<DateTime> pinnedAt = GeneratedColumn<DateTime>(
    'pinned_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    machineId,
    sessionId,
    path,
    cwd,
    title,
    firstMessage,
    pinnedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pinned_sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<PinnedSessionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('machine_id')) {
      context.handle(
        _machineIdMeta,
        machineId.isAcceptableOrUnknown(data['machine_id']!, _machineIdMeta),
      );
    } else if (isInserting) {
      context.missing(_machineIdMeta);
    }
    if (data.containsKey('session_id')) {
      context.handle(
        _sessionIdMeta,
        sessionId.isAcceptableOrUnknown(data['session_id']!, _sessionIdMeta),
      );
    } else if (isInserting) {
      context.missing(_sessionIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('cwd')) {
      context.handle(
        _cwdMeta,
        cwd.isAcceptableOrUnknown(data['cwd']!, _cwdMeta),
      );
    } else if (isInserting) {
      context.missing(_cwdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    }
    if (data.containsKey('first_message')) {
      context.handle(
        _firstMessageMeta,
        firstMessage.isAcceptableOrUnknown(
          data['first_message']!,
          _firstMessageMeta,
        ),
      );
    }
    if (data.containsKey('pinned_at')) {
      context.handle(
        _pinnedAtMeta,
        pinnedAt.isAcceptableOrUnknown(data['pinned_at']!, _pinnedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_pinnedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {machineId, sessionId};
  @override
  PinnedSessionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PinnedSessionRow(
      machineId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}machine_id'],
      )!,
      sessionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}session_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      cwd: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cwd'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      ),
      firstMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}first_message'],
      ),
      pinnedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}pinned_at'],
      )!,
    );
  }

  @override
  $PinnedSessionsTable createAlias(String alias) {
    return $PinnedSessionsTable(attachedDatabase, alias);
  }
}

class PinnedSessionRow extends DataClass
    implements Insertable<PinnedSessionRow> {
  final String machineId;
  final String sessionId;

  /// Host-native path of the session file.
  final String path;
  final String cwd;
  final String? title;
  final String? firstMessage;
  final DateTime pinnedAt;
  const PinnedSessionRow({
    required this.machineId,
    required this.sessionId,
    required this.path,
    required this.cwd,
    this.title,
    this.firstMessage,
    required this.pinnedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['machine_id'] = Variable<String>(machineId);
    map['session_id'] = Variable<String>(sessionId);
    map['path'] = Variable<String>(path);
    map['cwd'] = Variable<String>(cwd);
    if (!nullToAbsent || title != null) {
      map['title'] = Variable<String>(title);
    }
    if (!nullToAbsent || firstMessage != null) {
      map['first_message'] = Variable<String>(firstMessage);
    }
    map['pinned_at'] = Variable<DateTime>(pinnedAt);
    return map;
  }

  PinnedSessionsCompanion toCompanion(bool nullToAbsent) {
    return PinnedSessionsCompanion(
      machineId: Value(machineId),
      sessionId: Value(sessionId),
      path: Value(path),
      cwd: Value(cwd),
      title: title == null && nullToAbsent
          ? const Value.absent()
          : Value(title),
      firstMessage: firstMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(firstMessage),
      pinnedAt: Value(pinnedAt),
    );
  }

  factory PinnedSessionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PinnedSessionRow(
      machineId: serializer.fromJson<String>(json['machineId']),
      sessionId: serializer.fromJson<String>(json['sessionId']),
      path: serializer.fromJson<String>(json['path']),
      cwd: serializer.fromJson<String>(json['cwd']),
      title: serializer.fromJson<String?>(json['title']),
      firstMessage: serializer.fromJson<String?>(json['firstMessage']),
      pinnedAt: serializer.fromJson<DateTime>(json['pinnedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'machineId': serializer.toJson<String>(machineId),
      'sessionId': serializer.toJson<String>(sessionId),
      'path': serializer.toJson<String>(path),
      'cwd': serializer.toJson<String>(cwd),
      'title': serializer.toJson<String?>(title),
      'firstMessage': serializer.toJson<String?>(firstMessage),
      'pinnedAt': serializer.toJson<DateTime>(pinnedAt),
    };
  }

  PinnedSessionRow copyWith({
    String? machineId,
    String? sessionId,
    String? path,
    String? cwd,
    Value<String?> title = const Value.absent(),
    Value<String?> firstMessage = const Value.absent(),
    DateTime? pinnedAt,
  }) => PinnedSessionRow(
    machineId: machineId ?? this.machineId,
    sessionId: sessionId ?? this.sessionId,
    path: path ?? this.path,
    cwd: cwd ?? this.cwd,
    title: title.present ? title.value : this.title,
    firstMessage: firstMessage.present ? firstMessage.value : this.firstMessage,
    pinnedAt: pinnedAt ?? this.pinnedAt,
  );
  PinnedSessionRow copyWithCompanion(PinnedSessionsCompanion data) {
    return PinnedSessionRow(
      machineId: data.machineId.present ? data.machineId.value : this.machineId,
      sessionId: data.sessionId.present ? data.sessionId.value : this.sessionId,
      path: data.path.present ? data.path.value : this.path,
      cwd: data.cwd.present ? data.cwd.value : this.cwd,
      title: data.title.present ? data.title.value : this.title,
      firstMessage: data.firstMessage.present
          ? data.firstMessage.value
          : this.firstMessage,
      pinnedAt: data.pinnedAt.present ? data.pinnedAt.value : this.pinnedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PinnedSessionRow(')
          ..write('machineId: $machineId, ')
          ..write('sessionId: $sessionId, ')
          ..write('path: $path, ')
          ..write('cwd: $cwd, ')
          ..write('title: $title, ')
          ..write('firstMessage: $firstMessage, ')
          ..write('pinnedAt: $pinnedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    machineId,
    sessionId,
    path,
    cwd,
    title,
    firstMessage,
    pinnedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PinnedSessionRow &&
          other.machineId == this.machineId &&
          other.sessionId == this.sessionId &&
          other.path == this.path &&
          other.cwd == this.cwd &&
          other.title == this.title &&
          other.firstMessage == this.firstMessage &&
          other.pinnedAt == this.pinnedAt);
}

class PinnedSessionsCompanion extends UpdateCompanion<PinnedSessionRow> {
  final Value<String> machineId;
  final Value<String> sessionId;
  final Value<String> path;
  final Value<String> cwd;
  final Value<String?> title;
  final Value<String?> firstMessage;
  final Value<DateTime> pinnedAt;
  final Value<int> rowid;
  const PinnedSessionsCompanion({
    this.machineId = const Value.absent(),
    this.sessionId = const Value.absent(),
    this.path = const Value.absent(),
    this.cwd = const Value.absent(),
    this.title = const Value.absent(),
    this.firstMessage = const Value.absent(),
    this.pinnedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  PinnedSessionsCompanion.insert({
    required String machineId,
    required String sessionId,
    required String path,
    required String cwd,
    this.title = const Value.absent(),
    this.firstMessage = const Value.absent(),
    required DateTime pinnedAt,
    this.rowid = const Value.absent(),
  }) : machineId = Value(machineId),
       sessionId = Value(sessionId),
       path = Value(path),
       cwd = Value(cwd),
       pinnedAt = Value(pinnedAt);
  static Insertable<PinnedSessionRow> custom({
    Expression<String>? machineId,
    Expression<String>? sessionId,
    Expression<String>? path,
    Expression<String>? cwd,
    Expression<String>? title,
    Expression<String>? firstMessage,
    Expression<DateTime>? pinnedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (machineId != null) 'machine_id': machineId,
      if (sessionId != null) 'session_id': sessionId,
      if (path != null) 'path': path,
      if (cwd != null) 'cwd': cwd,
      if (title != null) 'title': title,
      if (firstMessage != null) 'first_message': firstMessage,
      if (pinnedAt != null) 'pinned_at': pinnedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  PinnedSessionsCompanion copyWith({
    Value<String>? machineId,
    Value<String>? sessionId,
    Value<String>? path,
    Value<String>? cwd,
    Value<String?>? title,
    Value<String?>? firstMessage,
    Value<DateTime>? pinnedAt,
    Value<int>? rowid,
  }) {
    return PinnedSessionsCompanion(
      machineId: machineId ?? this.machineId,
      sessionId: sessionId ?? this.sessionId,
      path: path ?? this.path,
      cwd: cwd ?? this.cwd,
      title: title ?? this.title,
      firstMessage: firstMessage ?? this.firstMessage,
      pinnedAt: pinnedAt ?? this.pinnedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (machineId.present) {
      map['machine_id'] = Variable<String>(machineId.value);
    }
    if (sessionId.present) {
      map['session_id'] = Variable<String>(sessionId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (cwd.present) {
      map['cwd'] = Variable<String>(cwd.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (firstMessage.present) {
      map['first_message'] = Variable<String>(firstMessage.value);
    }
    if (pinnedAt.present) {
      map['pinned_at'] = Variable<DateTime>(pinnedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PinnedSessionsCompanion(')
          ..write('machineId: $machineId, ')
          ..write('sessionId: $sessionId, ')
          ..write('path: $path, ')
          ..write('cwd: $cwd, ')
          ..write('title: $title, ')
          ..write('firstMessage: $firstMessage, ')
          ..write('pinnedAt: $pinnedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $SshKeysTable sshKeys = $SshKeysTable(this);
  late final $MachinesTable machines = $MachinesTable(this);
  late final $MachineJumpsTable machineJumps = $MachineJumpsTable(this);
  late final $KnownHostsTable knownHosts = $KnownHostsTable(this);
  late final $SettingsTable settings = $SettingsTable(this);
  late final $ReadMarkersTable readMarkers = $ReadMarkersTable(this);
  late final $PinnedSessionsTable pinnedSessions = $PinnedSessionsTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    sshKeys,
    machines,
    machineJumps,
    knownHosts,
    settings,
    readMarkers,
    pinnedSessions,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'ssh_keys',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('machines', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'machines',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('machine_jumps', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'ssh_keys',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('machine_jumps', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'machines',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('read_markers', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'machines',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('pinned_sessions', kind: UpdateKind.delete)],
    ),
  ]);
  @override
  DriftDatabaseOptions get options =>
      const DriftDatabaseOptions(storeDateTimeAsText: true);
}

typedef $$SshKeysTableCreateCompanionBuilder = SshKeysCompanion Function({
  required String id,
  required String name,
  required String type,
  required String publicKey,
  required String fingerprint,
  required DateTime createdAt,
  Value<int> rowid,
});
typedef $$SshKeysTableUpdateCompanionBuilder = SshKeysCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<String> type,
  Value<String> publicKey,
  Value<String> fingerprint,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

final class $$SshKeysTableReferences
    extends BaseReferences<_$AppDatabase, $SshKeysTable, SshKeyRow> {
  $$SshKeysTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MachinesTable, List<MachineRow>>
  _machinesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.machines,
    aliasName: 'ssh_keys__id__machines__key_id',
  );

  $$MachinesTableProcessedTableManager get machinesRefs {
    final manager = $$MachinesTableTableManager(
      $_db,
      $_db.machines,
    ).filter((f) => f.keyId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_machinesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$MachineJumpsTable, List<MachineJumpRow>>
  _machineJumpsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.machineJumps,
    aliasName: 'ssh_keys__id__machine_jumps__key_id',
  );

  $$MachineJumpsTableProcessedTableManager get machineJumpsRefs {
    final manager = $$MachineJumpsTableTableManager(
      $_db,
      $_db.machineJumps,
    ).filter((f) => f.keyId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_machineJumpsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SshKeysTableFilterComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get publicKey => $composableBuilder(
    column: $table.publicKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> machinesRefs(
    Expression<bool> Function($$MachinesTableFilterComposer f) f,
  ) {
    final $$MachinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.keyId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableFilterComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> machineJumpsRefs(
    Expression<bool> Function($$MachineJumpsTableFilterComposer f) f,
  ) {
    final $$MachineJumpsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.machineJumps,
      getReferencedColumn: (t) => t.keyId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachineJumpsTableFilterComposer(
            $db: $db,
            $table: $db.machineJumps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SshKeysTableOrderingComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get publicKey => $composableBuilder(
    column: $table.publicKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SshKeysTableAnnotationComposer
    extends Composer<_$AppDatabase, $SshKeysTable> {
  $$SshKeysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get publicKey =>
      $composableBuilder(column: $table.publicKey, builder: (column) => column);

  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> machinesRefs<T extends Object>(
    Expression<T> Function($$MachinesTableAnnotationComposer a) f,
  ) {
    final $$MachinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.keyId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableAnnotationComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> machineJumpsRefs<T extends Object>(
    Expression<T> Function($$MachineJumpsTableAnnotationComposer a) f,
  ) {
    final $$MachineJumpsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.machineJumps,
      getReferencedColumn: (t) => t.keyId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachineJumpsTableAnnotationComposer(
            $db: $db,
            $table: $db.machineJumps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SshKeysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SshKeysTable,
          SshKeyRow,
          $$SshKeysTableFilterComposer,
          $$SshKeysTableOrderingComposer,
          $$SshKeysTableAnnotationComposer,
          $$SshKeysTableCreateCompanionBuilder,
          $$SshKeysTableUpdateCompanionBuilder,
          (SshKeyRow, $$SshKeysTableReferences),
          SshKeyRow,
          PrefetchHooks Function({bool machinesRefs, bool machineJumpsRefs})
        > {
  $$SshKeysTableTableManager(_$AppDatabase db, $SshKeysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SshKeysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SshKeysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SshKeysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String> publicKey = const Value.absent(),
                Value<String> fingerprint = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SshKeysCompanion(
                id: id,
                name: name,
                type: type,
                publicKey: publicKey,
                fingerprint: fingerprint,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required String type,
                required String publicKey,
                required String fingerprint,
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => SshKeysCompanion.insert(
                id: id,
                name: name,
                type: type,
                publicKey: publicKey,
                fingerprint: fingerprint,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SshKeysTable, SshKeyRow>(table),
                  $$SshKeysTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({machinesRefs = false, machineJumpsRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (machinesRefs) db.machines,
                    if (machineJumpsRefs) db.machineJumps,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (machinesRefs)
                        await $_getPrefetchedData<
                          SshKeyRow,
                          $SshKeysTable,
                          MachineRow
                        >(
                          currentTable: table,
                          referencedTable: $$SshKeysTableReferences
                              ._machinesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SshKeysTableReferences(
                                db,
                                table,
                                p0,
                              ).machinesRefs,
                          referencedItemsForCurrentItem: (
                            item,
                            referencedItems,
                          ) => referencedItems.where((e) => e.keyId == item.id),
                          typedResults: items,
                        ),
                      if (machineJumpsRefs)
                        await $_getPrefetchedData<
                          SshKeyRow,
                          $SshKeysTable,
                          MachineJumpRow
                        >(
                          currentTable: table,
                          referencedTable: $$SshKeysTableReferences
                              ._machineJumpsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$SshKeysTableReferences(
                                db,
                                table,
                                p0,
                              ).machineJumpsRefs,
                          referencedItemsForCurrentItem: (
                            item,
                            referencedItems,
                          ) => referencedItems.where((e) => e.keyId == item.id),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$SshKeysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SshKeysTable,
      SshKeyRow,
      $$SshKeysTableFilterComposer,
      $$SshKeysTableOrderingComposer,
      $$SshKeysTableAnnotationComposer,
      $$SshKeysTableCreateCompanionBuilder,
      $$SshKeysTableUpdateCompanionBuilder,
      (SshKeyRow, $$SshKeysTableReferences),
      SshKeyRow,
      PrefetchHooks Function({bool machinesRefs, bool machineJumpsRefs})
    >;
typedef $$MachinesTableCreateCompanionBuilder = MachinesCompanion Function({
  required String id,
  required String name,
  required MachineKind kind,
  Value<String?> host,
  Value<int> port,
  Value<String?> user,
  Value<AuthMethod?> auth,
  Value<String?> keyId,
  Value<String?> sshConfigAlias,
  Value<bool> tailscale,
  required DateTime createdAt,
  required DateTime updatedAt,
  Value<int> rowid,
});
typedef $$MachinesTableUpdateCompanionBuilder = MachinesCompanion Function({
  Value<String> id,
  Value<String> name,
  Value<MachineKind> kind,
  Value<String?> host,
  Value<int> port,
  Value<String?> user,
  Value<AuthMethod?> auth,
  Value<String?> keyId,
  Value<String?> sshConfigAlias,
  Value<bool> tailscale,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<int> rowid,
});

final class $$MachinesTableReferences
    extends BaseReferences<_$AppDatabase, $MachinesTable, MachineRow> {
  $$MachinesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $SshKeysTable _keyIdTable(_$AppDatabase db) =>
      db.sshKeys.createAlias('machines__key_id__ssh_keys__id');

  $$SshKeysTableProcessedTableManager? get keyId {
    final $_column = $_itemColumn<String>('key_id');
    if ($_column == null) return null;
    final manager = $$SshKeysTableTableManager(
      $_db,
      $_db.sshKeys,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_keyIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$MachineJumpsTable, List<MachineJumpRow>>
  _machineJumpsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.machineJumps,
    aliasName: 'machines__id__machine_jumps__machine_id',
  );

  $$MachineJumpsTableProcessedTableManager get machineJumpsRefs {
    final manager = $$MachineJumpsTableTableManager(
      $_db,
      $_db.machineJumps,
    ).filter((f) => f.machineId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_machineJumpsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$ReadMarkersTable, List<ReadMarkerRow>>
  _readMarkersRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.readMarkers,
    aliasName: 'machines__id__read_markers__machine_id',
  );

  $$ReadMarkersTableProcessedTableManager get readMarkersRefs {
    final manager = $$ReadMarkersTableTableManager(
      $_db,
      $_db.readMarkers,
    ).filter((f) => f.machineId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_readMarkersRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$PinnedSessionsTable, List<PinnedSessionRow>>
  _pinnedSessionsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.pinnedSessions,
    aliasName: 'machines__id__pinned_sessions__machine_id',
  );

  $$PinnedSessionsTableProcessedTableManager get pinnedSessionsRefs {
    final manager = $$PinnedSessionsTableTableManager(
      $_db,
      $_db.pinnedSessions,
    ).filter((f) => f.machineId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_pinnedSessionsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MachinesTableFilterComposer
    extends Composer<_$AppDatabase, $MachinesTable> {
  $$MachinesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<MachineKind, MachineKind, String> get kind =>
      $composableBuilder(
        column: $table.kind,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get user => $composableBuilder(
    column: $table.user,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<AuthMethod?, AuthMethod, String> get auth =>
      $composableBuilder(
        column: $table.auth,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  ColumnFilters<String> get sshConfigAlias => $composableBuilder(
    column: $table.sshConfigAlias,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get tailscale => $composableBuilder(
    column: $table.tailscale,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$SshKeysTableFilterComposer get keyId {
    final $$SshKeysTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableFilterComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> machineJumpsRefs(
    Expression<bool> Function($$MachineJumpsTableFilterComposer f) f,
  ) {
    final $$MachineJumpsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.machineJumps,
      getReferencedColumn: (t) => t.machineId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachineJumpsTableFilterComposer(
            $db: $db,
            $table: $db.machineJumps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> readMarkersRefs(
    Expression<bool> Function($$ReadMarkersTableFilterComposer f) f,
  ) {
    final $$ReadMarkersTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.readMarkers,
      getReferencedColumn: (t) => t.machineId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReadMarkersTableFilterComposer(
            $db: $db,
            $table: $db.readMarkers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> pinnedSessionsRefs(
    Expression<bool> Function($$PinnedSessionsTableFilterComposer f) f,
  ) {
    final $$PinnedSessionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.pinnedSessions,
      getReferencedColumn: (t) => t.machineId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PinnedSessionsTableFilterComposer(
            $db: $db,
            $table: $db.pinnedSessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MachinesTableOrderingComposer
    extends Composer<_$AppDatabase, $MachinesTable> {
  $$MachinesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get user => $composableBuilder(
    column: $table.user,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get auth => $composableBuilder(
    column: $table.auth,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sshConfigAlias => $composableBuilder(
    column: $table.sshConfigAlias,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get tailscale => $composableBuilder(
    column: $table.tailscale,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$SshKeysTableOrderingComposer get keyId {
    final $$SshKeysTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableOrderingComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MachinesTableAnnotationComposer
    extends Composer<_$AppDatabase, $MachinesTable> {
  $$MachinesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumnWithTypeConverter<MachineKind, String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get host =>
      $composableBuilder(column: $table.host, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get user =>
      $composableBuilder(column: $table.user, builder: (column) => column);

  GeneratedColumnWithTypeConverter<AuthMethod?, String> get auth =>
      $composableBuilder(column: $table.auth, builder: (column) => column);

  GeneratedColumn<String> get sshConfigAlias => $composableBuilder(
    column: $table.sshConfigAlias,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get tailscale =>
      $composableBuilder(column: $table.tailscale, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$SshKeysTableAnnotationComposer get keyId {
    final $$SshKeysTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableAnnotationComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> machineJumpsRefs<T extends Object>(
    Expression<T> Function($$MachineJumpsTableAnnotationComposer a) f,
  ) {
    final $$MachineJumpsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.machineJumps,
      getReferencedColumn: (t) => t.machineId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachineJumpsTableAnnotationComposer(
            $db: $db,
            $table: $db.machineJumps,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> readMarkersRefs<T extends Object>(
    Expression<T> Function($$ReadMarkersTableAnnotationComposer a) f,
  ) {
    final $$ReadMarkersTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.readMarkers,
      getReferencedColumn: (t) => t.machineId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ReadMarkersTableAnnotationComposer(
            $db: $db,
            $table: $db.readMarkers,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> pinnedSessionsRefs<T extends Object>(
    Expression<T> Function($$PinnedSessionsTableAnnotationComposer a) f,
  ) {
    final $$PinnedSessionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.pinnedSessions,
      getReferencedColumn: (t) => t.machineId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$PinnedSessionsTableAnnotationComposer(
            $db: $db,
            $table: $db.pinnedSessions,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MachinesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MachinesTable,
          MachineRow,
          $$MachinesTableFilterComposer,
          $$MachinesTableOrderingComposer,
          $$MachinesTableAnnotationComposer,
          $$MachinesTableCreateCompanionBuilder,
          $$MachinesTableUpdateCompanionBuilder,
          (MachineRow, $$MachinesTableReferences),
          MachineRow,
          PrefetchHooks Function({
            bool keyId,
            bool machineJumpsRefs,
            bool readMarkersRefs,
            bool pinnedSessionsRefs,
          })
        > {
  $$MachinesTableTableManager(_$AppDatabase db, $MachinesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MachinesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MachinesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MachinesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<MachineKind> kind = const Value.absent(),
                Value<String?> host = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String?> user = const Value.absent(),
                Value<AuthMethod?> auth = const Value.absent(),
                Value<String?> keyId = const Value.absent(),
                Value<String?> sshConfigAlias = const Value.absent(),
                Value<bool> tailscale = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MachinesCompanion(
                id: id,
                name: name,
                kind: kind,
                host: host,
                port: port,
                user: user,
                auth: auth,
                keyId: keyId,
                sshConfigAlias: sshConfigAlias,
                tailscale: tailscale,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                required MachineKind kind,
                Value<String?> host = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String?> user = const Value.absent(),
                Value<AuthMethod?> auth = const Value.absent(),
                Value<String?> keyId = const Value.absent(),
                Value<String?> sshConfigAlias = const Value.absent(),
                Value<bool> tailscale = const Value.absent(),
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => MachinesCompanion.insert(
                id: id,
                name: name,
                kind: kind,
                host: host,
                port: port,
                user: user,
                auth: auth,
                keyId: keyId,
                sshConfigAlias: sshConfigAlias,
                tailscale: tailscale,
                createdAt: createdAt,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MachinesTable, MachineRow>(table),
                  $$MachinesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                keyId = false,
                machineJumpsRefs = false,
                readMarkersRefs = false,
                pinnedSessionsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (machineJumpsRefs) db.machineJumps,
                    if (readMarkersRefs) db.readMarkers,
                    if (pinnedSessionsRefs) db.pinnedSessions,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (keyId) {
                          state = state.withJoin(
                            currentTable: table,
                            currentColumn: table.keyId,
                            referencedTable: $$MachinesTableReferences
                                ._keyIdTable(db),
                            referencedColumn: $$MachinesTableReferences
                                ._keyIdTable(db)
                                .id,
                          ) as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (machineJumpsRefs)
                        await $_getPrefetchedData<
                          MachineRow,
                          $MachinesTable,
                          MachineJumpRow
                        >(
                          currentTable: table,
                          referencedTable: $$MachinesTableReferences
                              ._machineJumpsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MachinesTableReferences(
                                db,
                                table,
                                p0,
                              ).machineJumpsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.machineId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (readMarkersRefs)
                        await $_getPrefetchedData<
                          MachineRow,
                          $MachinesTable,
                          ReadMarkerRow
                        >(
                          currentTable: table,
                          referencedTable: $$MachinesTableReferences
                              ._readMarkersRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MachinesTableReferences(
                                db,
                                table,
                                p0,
                              ).readMarkersRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.machineId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (pinnedSessionsRefs)
                        await $_getPrefetchedData<
                          MachineRow,
                          $MachinesTable,
                          PinnedSessionRow
                        >(
                          currentTable: table,
                          referencedTable: $$MachinesTableReferences
                              ._pinnedSessionsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MachinesTableReferences(
                                db,
                                table,
                                p0,
                              ).pinnedSessionsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.machineId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$MachinesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MachinesTable,
      MachineRow,
      $$MachinesTableFilterComposer,
      $$MachinesTableOrderingComposer,
      $$MachinesTableAnnotationComposer,
      $$MachinesTableCreateCompanionBuilder,
      $$MachinesTableUpdateCompanionBuilder,
      (MachineRow, $$MachinesTableReferences),
      MachineRow,
      PrefetchHooks Function({
        bool keyId,
        bool machineJumpsRefs,
        bool readMarkersRefs,
        bool pinnedSessionsRefs,
      })
    >;
typedef $$MachineJumpsTableCreateCompanionBuilder =
    MachineJumpsCompanion Function({
      required String id,
      required String machineId,
      required int position,
      required String host,
      Value<int> port,
      required String user,
      required AuthMethod auth,
      Value<String?> keyId,
      Value<int> rowid,
    });
typedef $$MachineJumpsTableUpdateCompanionBuilder =
    MachineJumpsCompanion Function({
      Value<String> id,
      Value<String> machineId,
      Value<int> position,
      Value<String> host,
      Value<int> port,
      Value<String> user,
      Value<AuthMethod> auth,
      Value<String?> keyId,
      Value<int> rowid,
    });

final class $$MachineJumpsTableReferences
    extends BaseReferences<_$AppDatabase, $MachineJumpsTable, MachineJumpRow> {
  $$MachineJumpsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MachinesTable _machineIdTable(_$AppDatabase db) =>
      db.machines.createAlias('machine_jumps__machine_id__machines__id');

  $$MachinesTableProcessedTableManager get machineId {
    final $_column = $_itemColumn<String>('machine_id')!;

    final manager = $$MachinesTableTableManager(
      $_db,
      $_db.machines,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_machineIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $SshKeysTable _keyIdTable(_$AppDatabase db) =>
      db.sshKeys.createAlias('machine_jumps__key_id__ssh_keys__id');

  $$SshKeysTableProcessedTableManager? get keyId {
    final $_column = $_itemColumn<String>('key_id');
    if ($_column == null) return null;
    final manager = $$SshKeysTableTableManager(
      $_db,
      $_db.sshKeys,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_keyIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$MachineJumpsTableFilterComposer
    extends Composer<_$AppDatabase, $MachineJumpsTable> {
  $$MachineJumpsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get user => $composableBuilder(
    column: $table.user,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<AuthMethod, AuthMethod, String> get auth =>
      $composableBuilder(
        column: $table.auth,
        builder: (column) => ColumnWithTypeConverterFilters(column),
      );

  $$MachinesTableFilterComposer get machineId {
    final $$MachinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableFilterComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SshKeysTableFilterComposer get keyId {
    final $$SshKeysTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableFilterComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MachineJumpsTableOrderingComposer
    extends Composer<_$AppDatabase, $MachineJumpsTable> {
  $$MachineJumpsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get user => $composableBuilder(
    column: $table.user,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get auth => $composableBuilder(
    column: $table.auth,
    builder: (column) => ColumnOrderings(column),
  );

  $$MachinesTableOrderingComposer get machineId {
    final $$MachinesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableOrderingComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SshKeysTableOrderingComposer get keyId {
    final $$SshKeysTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableOrderingComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MachineJumpsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MachineJumpsTable> {
  $$MachineJumpsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get host =>
      $composableBuilder(column: $table.host, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get user =>
      $composableBuilder(column: $table.user, builder: (column) => column);

  GeneratedColumnWithTypeConverter<AuthMethod, String> get auth =>
      $composableBuilder(column: $table.auth, builder: (column) => column);

  $$MachinesTableAnnotationComposer get machineId {
    final $$MachinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableAnnotationComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$SshKeysTableAnnotationComposer get keyId {
    final $$SshKeysTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.keyId,
      referencedTable: $db.sshKeys,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SshKeysTableAnnotationComposer(
            $db: $db,
            $table: $db.sshKeys,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MachineJumpsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MachineJumpsTable,
          MachineJumpRow,
          $$MachineJumpsTableFilterComposer,
          $$MachineJumpsTableOrderingComposer,
          $$MachineJumpsTableAnnotationComposer,
          $$MachineJumpsTableCreateCompanionBuilder,
          $$MachineJumpsTableUpdateCompanionBuilder,
          (MachineJumpRow, $$MachineJumpsTableReferences),
          MachineJumpRow,
          PrefetchHooks Function({bool machineId, bool keyId})
        > {
  $$MachineJumpsTableTableManager(_$AppDatabase db, $MachineJumpsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MachineJumpsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MachineJumpsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MachineJumpsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> machineId = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<String> host = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> user = const Value.absent(),
                Value<AuthMethod> auth = const Value.absent(),
                Value<String?> keyId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MachineJumpsCompanion(
                id: id,
                machineId: machineId,
                position: position,
                host: host,
                port: port,
                user: user,
                auth: auth,
                keyId: keyId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String machineId,
                required int position,
                required String host,
                Value<int> port = const Value.absent(),
                required String user,
                required AuthMethod auth,
                Value<String?> keyId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MachineJumpsCompanion.insert(
                id: id,
                machineId: machineId,
                position: position,
                host: host,
                port: port,
                user: user,
                auth: auth,
                keyId: keyId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MachineJumpsTable, MachineJumpRow>(table),
                  $$MachineJumpsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({machineId = false, keyId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (machineId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.machineId,
                        referencedTable: $$MachineJumpsTableReferences
                            ._machineIdTable(db),
                        referencedColumn: $$MachineJumpsTableReferences
                            ._machineIdTable(db)
                            .id,
                      ) as T;
                    }
                    if (keyId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.keyId,
                        referencedTable: $$MachineJumpsTableReferences
                            ._keyIdTable(db),
                        referencedColumn: $$MachineJumpsTableReferences
                            ._keyIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MachineJumpsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MachineJumpsTable,
      MachineJumpRow,
      $$MachineJumpsTableFilterComposer,
      $$MachineJumpsTableOrderingComposer,
      $$MachineJumpsTableAnnotationComposer,
      $$MachineJumpsTableCreateCompanionBuilder,
      $$MachineJumpsTableUpdateCompanionBuilder,
      (MachineJumpRow, $$MachineJumpsTableReferences),
      MachineJumpRow,
      PrefetchHooks Function({bool machineId, bool keyId})
    >;
typedef $$KnownHostsTableCreateCompanionBuilder = KnownHostsCompanion Function({
  required String host,
  required int port,
  required String keyType,
  required String keyBlob,
  required String fingerprint,
  required DateTime addedAt,
  Value<int> rowid,
});
typedef $$KnownHostsTableUpdateCompanionBuilder = KnownHostsCompanion Function({
  Value<String> host,
  Value<int> port,
  Value<String> keyType,
  Value<String> keyBlob,
  Value<String> fingerprint,
  Value<DateTime> addedAt,
  Value<int> rowid,
});

class $$KnownHostsTableFilterComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get keyBlob => $composableBuilder(
    column: $table.keyBlob,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$KnownHostsTableOrderingComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get host => $composableBuilder(
    column: $table.host,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get port => $composableBuilder(
    column: $table.port,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get keyType => $composableBuilder(
    column: $table.keyType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get keyBlob => $composableBuilder(
    column: $table.keyBlob,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$KnownHostsTableAnnotationComposer
    extends Composer<_$AppDatabase, $KnownHostsTable> {
  $$KnownHostsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get host =>
      $composableBuilder(column: $table.host, builder: (column) => column);

  GeneratedColumn<int> get port =>
      $composableBuilder(column: $table.port, builder: (column) => column);

  GeneratedColumn<String> get keyType =>
      $composableBuilder(column: $table.keyType, builder: (column) => column);

  GeneratedColumn<String> get keyBlob =>
      $composableBuilder(column: $table.keyBlob, builder: (column) => column);

  GeneratedColumn<String> get fingerprint => $composableBuilder(
    column: $table.fingerprint,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);
}

class $$KnownHostsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KnownHostsTable,
          KnownHostRow,
          $$KnownHostsTableFilterComposer,
          $$KnownHostsTableOrderingComposer,
          $$KnownHostsTableAnnotationComposer,
          $$KnownHostsTableCreateCompanionBuilder,
          $$KnownHostsTableUpdateCompanionBuilder,
          (
            KnownHostRow,
            BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHostRow>,
          ),
          KnownHostRow,
          PrefetchHooks Function()
        > {
  $$KnownHostsTableTableManager(_$AppDatabase db, $KnownHostsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$KnownHostsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$KnownHostsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$KnownHostsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> host = const Value.absent(),
                Value<int> port = const Value.absent(),
                Value<String> keyType = const Value.absent(),
                Value<String> keyBlob = const Value.absent(),
                Value<String> fingerprint = const Value.absent(),
                Value<DateTime> addedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => KnownHostsCompanion(
                host: host,
                port: port,
                keyType: keyType,
                keyBlob: keyBlob,
                fingerprint: fingerprint,
                addedAt: addedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String host,
                required int port,
                required String keyType,
                required String keyBlob,
                required String fingerprint,
                required DateTime addedAt,
                Value<int> rowid = const Value.absent(),
              }) => KnownHostsCompanion.insert(
                host: host,
                port: port,
                keyType: keyType,
                keyBlob: keyBlob,
                fingerprint: fingerprint,
                addedAt: addedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KnownHostsTable, KnownHostRow>(table),
                  BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHostRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KnownHostsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KnownHostsTable,
      KnownHostRow,
      $$KnownHostsTableFilterComposer,
      $$KnownHostsTableOrderingComposer,
      $$KnownHostsTableAnnotationComposer,
      $$KnownHostsTableCreateCompanionBuilder,
      $$KnownHostsTableUpdateCompanionBuilder,
      (
        KnownHostRow,
        BaseReferences<_$AppDatabase, $KnownHostsTable, KnownHostRow>,
      ),
      KnownHostRow,
      PrefetchHooks Function()
    >;
typedef $$SettingsTableCreateCompanionBuilder = SettingsCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$SettingsTableUpdateCompanionBuilder = SettingsCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$SettingsTableFilterComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$SettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SettingsTable> {
  $$SettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$SettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SettingsTable,
          SettingRow,
          $$SettingsTableFilterComposer,
          $$SettingsTableOrderingComposer,
          $$SettingsTableAnnotationComposer,
          $$SettingsTableCreateCompanionBuilder,
          $$SettingsTableUpdateCompanionBuilder,
          (
            SettingRow,
            BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>,
          ),
          SettingRow,
          PrefetchHooks Function()
        > {
  $$SettingsTableTableManager(_$AppDatabase db, $SettingsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => SettingsCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => SettingsCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$SettingsTable, SettingRow>(table),
                  BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$SettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SettingsTable,
      SettingRow,
      $$SettingsTableFilterComposer,
      $$SettingsTableOrderingComposer,
      $$SettingsTableAnnotationComposer,
      $$SettingsTableCreateCompanionBuilder,
      $$SettingsTableUpdateCompanionBuilder,
      (SettingRow, BaseReferences<_$AppDatabase, $SettingsTable, SettingRow>),
      SettingRow,
      PrefetchHooks Function()
    >;
typedef $$ReadMarkersTableCreateCompanionBuilder =
    ReadMarkersCompanion Function({
      required String machineId,
      required String path,
      required DateTime seenModified,
      Value<int> rowid,
    });
typedef $$ReadMarkersTableUpdateCompanionBuilder =
    ReadMarkersCompanion Function({
      Value<String> machineId,
      Value<String> path,
      Value<DateTime> seenModified,
      Value<int> rowid,
    });

final class $$ReadMarkersTableReferences
    extends BaseReferences<_$AppDatabase, $ReadMarkersTable, ReadMarkerRow> {
  $$ReadMarkersTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MachinesTable _machineIdTable(_$AppDatabase db) =>
      db.machines.createAlias('read_markers__machine_id__machines__id');

  $$MachinesTableProcessedTableManager get machineId {
    final $_column = $_itemColumn<String>('machine_id')!;

    final manager = $$MachinesTableTableManager(
      $_db,
      $_db.machines,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_machineIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ReadMarkersTableFilterComposer
    extends Composer<_$AppDatabase, $ReadMarkersTable> {
  $$ReadMarkersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get seenModified => $composableBuilder(
    column: $table.seenModified,
    builder: (column) => ColumnFilters(column),
  );

  $$MachinesTableFilterComposer get machineId {
    final $$MachinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableFilterComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReadMarkersTableOrderingComposer
    extends Composer<_$AppDatabase, $ReadMarkersTable> {
  $$ReadMarkersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get seenModified => $composableBuilder(
    column: $table.seenModified,
    builder: (column) => ColumnOrderings(column),
  );

  $$MachinesTableOrderingComposer get machineId {
    final $$MachinesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableOrderingComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReadMarkersTableAnnotationComposer
    extends Composer<_$AppDatabase, $ReadMarkersTable> {
  $$ReadMarkersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<DateTime> get seenModified => $composableBuilder(
    column: $table.seenModified,
    builder: (column) => column,
  );

  $$MachinesTableAnnotationComposer get machineId {
    final $$MachinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableAnnotationComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ReadMarkersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ReadMarkersTable,
          ReadMarkerRow,
          $$ReadMarkersTableFilterComposer,
          $$ReadMarkersTableOrderingComposer,
          $$ReadMarkersTableAnnotationComposer,
          $$ReadMarkersTableCreateCompanionBuilder,
          $$ReadMarkersTableUpdateCompanionBuilder,
          (ReadMarkerRow, $$ReadMarkersTableReferences),
          ReadMarkerRow,
          PrefetchHooks Function({bool machineId})
        > {
  $$ReadMarkersTableTableManager(_$AppDatabase db, $ReadMarkersTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ReadMarkersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ReadMarkersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ReadMarkersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> machineId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<DateTime> seenModified = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ReadMarkersCompanion(
                machineId: machineId,
                path: path,
                seenModified: seenModified,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String machineId,
                required String path,
                required DateTime seenModified,
                Value<int> rowid = const Value.absent(),
              }) => ReadMarkersCompanion.insert(
                machineId: machineId,
                path: path,
                seenModified: seenModified,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ReadMarkersTable, ReadMarkerRow>(table),
                  $$ReadMarkersTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({machineId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (machineId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.machineId,
                        referencedTable: $$ReadMarkersTableReferences
                            ._machineIdTable(db),
                        referencedColumn: $$ReadMarkersTableReferences
                            ._machineIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ReadMarkersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ReadMarkersTable,
      ReadMarkerRow,
      $$ReadMarkersTableFilterComposer,
      $$ReadMarkersTableOrderingComposer,
      $$ReadMarkersTableAnnotationComposer,
      $$ReadMarkersTableCreateCompanionBuilder,
      $$ReadMarkersTableUpdateCompanionBuilder,
      (ReadMarkerRow, $$ReadMarkersTableReferences),
      ReadMarkerRow,
      PrefetchHooks Function({bool machineId})
    >;
typedef $$PinnedSessionsTableCreateCompanionBuilder =
    PinnedSessionsCompanion Function({
      required String machineId,
      required String sessionId,
      required String path,
      required String cwd,
      Value<String?> title,
      Value<String?> firstMessage,
      required DateTime pinnedAt,
      Value<int> rowid,
    });
typedef $$PinnedSessionsTableUpdateCompanionBuilder =
    PinnedSessionsCompanion Function({
      Value<String> machineId,
      Value<String> sessionId,
      Value<String> path,
      Value<String> cwd,
      Value<String?> title,
      Value<String?> firstMessage,
      Value<DateTime> pinnedAt,
      Value<int> rowid,
    });

final class $$PinnedSessionsTableReferences
    extends
        BaseReferences<_$AppDatabase, $PinnedSessionsTable, PinnedSessionRow> {
  $$PinnedSessionsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MachinesTable _machineIdTable(_$AppDatabase db) =>
      db.machines.createAlias('pinned_sessions__machine_id__machines__id');

  $$MachinesTableProcessedTableManager get machineId {
    final $_column = $_itemColumn<String>('machine_id')!;

    final manager = $$MachinesTableTableManager(
      $_db,
      $_db.machines,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_machineIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$PinnedSessionsTableFilterComposer
    extends Composer<_$AppDatabase, $PinnedSessionsTable> {
  $$PinnedSessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get cwd => $composableBuilder(
    column: $table.cwd,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get firstMessage => $composableBuilder(
    column: $table.firstMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get pinnedAt => $composableBuilder(
    column: $table.pinnedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$MachinesTableFilterComposer get machineId {
    final $$MachinesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableFilterComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PinnedSessionsTableOrderingComposer
    extends Composer<_$AppDatabase, $PinnedSessionsTable> {
  $$PinnedSessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get sessionId => $composableBuilder(
    column: $table.sessionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get cwd => $composableBuilder(
    column: $table.cwd,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get firstMessage => $composableBuilder(
    column: $table.firstMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get pinnedAt => $composableBuilder(
    column: $table.pinnedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$MachinesTableOrderingComposer get machineId {
    final $$MachinesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableOrderingComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PinnedSessionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $PinnedSessionsTable> {
  $$PinnedSessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get sessionId =>
      $composableBuilder(column: $table.sessionId, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get cwd =>
      $composableBuilder(column: $table.cwd, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get firstMessage => $composableBuilder(
    column: $table.firstMessage,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get pinnedAt =>
      $composableBuilder(column: $table.pinnedAt, builder: (column) => column);

  $$MachinesTableAnnotationComposer get machineId {
    final $$MachinesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.machineId,
      referencedTable: $db.machines,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MachinesTableAnnotationComposer(
            $db: $db,
            $table: $db.machines,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$PinnedSessionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PinnedSessionsTable,
          PinnedSessionRow,
          $$PinnedSessionsTableFilterComposer,
          $$PinnedSessionsTableOrderingComposer,
          $$PinnedSessionsTableAnnotationComposer,
          $$PinnedSessionsTableCreateCompanionBuilder,
          $$PinnedSessionsTableUpdateCompanionBuilder,
          (PinnedSessionRow, $$PinnedSessionsTableReferences),
          PinnedSessionRow,
          PrefetchHooks Function({bool machineId})
        > {
  $$PinnedSessionsTableTableManager(
    _$AppDatabase db,
    $PinnedSessionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PinnedSessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PinnedSessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PinnedSessionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> machineId = const Value.absent(),
                Value<String> sessionId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String> cwd = const Value.absent(),
                Value<String?> title = const Value.absent(),
                Value<String?> firstMessage = const Value.absent(),
                Value<DateTime> pinnedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => PinnedSessionsCompanion(
                machineId: machineId,
                sessionId: sessionId,
                path: path,
                cwd: cwd,
                title: title,
                firstMessage: firstMessage,
                pinnedAt: pinnedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String machineId,
                required String sessionId,
                required String path,
                required String cwd,
                Value<String?> title = const Value.absent(),
                Value<String?> firstMessage = const Value.absent(),
                required DateTime pinnedAt,
                Value<int> rowid = const Value.absent(),
              }) => PinnedSessionsCompanion.insert(
                machineId: machineId,
                sessionId: sessionId,
                path: path,
                cwd: cwd,
                title: title,
                firstMessage: firstMessage,
                pinnedAt: pinnedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PinnedSessionsTable, PinnedSessionRow>(table),
                  $$PinnedSessionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({machineId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (machineId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.machineId,
                        referencedTable: $$PinnedSessionsTableReferences
                            ._machineIdTable(db),
                        referencedColumn: $$PinnedSessionsTableReferences
                            ._machineIdTable(db)
                            .id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$PinnedSessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PinnedSessionsTable,
      PinnedSessionRow,
      $$PinnedSessionsTableFilterComposer,
      $$PinnedSessionsTableOrderingComposer,
      $$PinnedSessionsTableAnnotationComposer,
      $$PinnedSessionsTableCreateCompanionBuilder,
      $$PinnedSessionsTableUpdateCompanionBuilder,
      (PinnedSessionRow, $$PinnedSessionsTableReferences),
      PinnedSessionRow,
      PrefetchHooks Function({bool machineId})
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$SshKeysTableTableManager get sshKeys =>
      $$SshKeysTableTableManager(_db, _db.sshKeys);
  $$MachinesTableTableManager get machines =>
      $$MachinesTableTableManager(_db, _db.machines);
  $$MachineJumpsTableTableManager get machineJumps =>
      $$MachineJumpsTableTableManager(_db, _db.machineJumps);
  $$KnownHostsTableTableManager get knownHosts =>
      $$KnownHostsTableTableManager(_db, _db.knownHosts);
  $$SettingsTableTableManager get settings =>
      $$SettingsTableTableManager(_db, _db.settings);
  $$ReadMarkersTableTableManager get readMarkers =>
      $$ReadMarkersTableTableManager(_db, _db.readMarkers);
  $$PinnedSessionsTableTableManager get pinnedSessions =>
      $$PinnedSessionsTableTableManager(_db, _db.pinnedSessions);
}
