import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/providers/shell_provider.dart';
import 'package:ompanion/screens/sessions/new_session_dialog.dart';
import 'package:ompanion/services/known_hosts_store.dart';
import 'package:ompanion/services/machine_connector.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:provider/provider.dart';

/// Records whether it was closed.
final class _Files implements HostFiles {
  _Files(this._inner);

  final HostFiles _inner;
  bool closed = false;

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) => _inner.stat(path, followLinks: followLinks);

  @override
  Future<List<HostDirEntry>> list(String path) => _inner.list(path);

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) =>
      _inner.read(path, offset: offset, length: length);

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) =>
      _inner.write(path, bytes, append: append, mode: mode);

  @override
  Future<void> mkdir(String path, {int? mode}) => _inner.mkdir(path, mode: mode);

  @override
  Future<void> remove(String path) => _inner.remove(path);

  @override
  Future<void> removeDir(String path) => _inner.removeDir(path);

  @override
  Future<void> rename(String from, String to) => _inner.rename(from, to);

  @override
  Future<String> home() => _inner.home();

  @override
  Future<void> close() {
    closed = true;
    return _inner.close();
  }
}

/// This computer, with SFTP channels that open only once [hold] completes.
final class _Link implements HostLink {
  _Link(this._inner);

  final HostLink _inner;
  Completer<void>? hold;
  final opened = <_Files>[];

  @override
  String get label => _inner.label;

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) => _inner.exec(command, pty: pty);

  @override
  Future<HostFiles> files() async {
    await hold?.future;
    final files = _Files(await _inner.files());
    opened.add(files);
    return files;
  }

  @override
  Future<HostSocket> connect(String host, int port) => _inner.connect(host, port);

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();
}

final class _Connector extends MachineConnector {
  _Connector(super.secrets, super.knownHosts, this.link);

  final _Link link;

  @override
  Future<HostLink> open(Machine machine, ConnectPrompts prompts) async => link;

  @override
  bool searchSystemPaths(Machine machine) => false;
}

void main() {
  testWidgets('a directory picker closed while its SFTP channel opens closes the channel', (tester) async {
    final home = Directory.systemTemp.createTempSync('ompanion-picker-');
    addTearDown(() => home.deleteSync(recursive: true));
    final omp = File('${home.path}/.local/bin/omp')..createSync(recursive: true);
    omp.writeAsStringSync('#!/bin/sh\necho omp/18.3.1\n');
    Process.runSync('chmod', ['+x', omp.path]);
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final secrets = SecretStore();
    final machines = MachinesProvider(db, secrets);
    final link = _Link(LocalLink(environment: {'HOME': home.path, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin'}));
    final sessions = SessionsProvider(
      connector: _Connector(secrets, KnownHostsStore(db), link),
      machines: machines,
      deviceId: 'test',
      companionBytes: (_) async => utf8.encode('// companion'),
    );
    final machine = LocalMachine(id: 'm1', name: 'here', createdAt: DateTime(2026), updatedAt: DateTime(2026));
    // The provider ends the runtimes of machines that are not saved.
    await tester.runAsync(() async {
      await machines.save(machine);
      for (var i = 0; i < 200 && machines.byId(machine.id) == null; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await sessions.runtimeFor(machine).connectAndProbe();
    });
    expect(sessions.runtimeFor(machine).status, isA<MachineOnline>());

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: sessions),
          ChangeNotifierProvider(create: (_) => ShellProvider()),
        ],
        child: TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(showNewSessionDialog(context, machine)),
                child: const Text('new'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('new'));
    await tester.pumpAndSettle();

    // Connecting opened one channel already, for the companion upload.
    final before = link.opened.length;
    final hold = link.hold = Completer<void>();
    await tester.tap(find.byTooltip('Browse the machine'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(TextButton, 'Cancel').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    hold.complete();
    for (var i = 0; i < 50 && link.opened.length == before; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pump();
    expect(link.opened.skip(before).single.closed, isTrue);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      sessions.dispose();
      machines.dispose();
      await db.close();
    });
  });
}
