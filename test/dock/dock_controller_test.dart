import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/providers/machines_provider.dart';
import 'package:ompanion/screens/dock/dock_controller.dart';
import 'package:ompanion/services/secret_store.dart';
import 'package:ompanion/terminal/terminal_session.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';

/// A shell that runs until it is closed.
final class _Backend implements TerminalBackend {
  var closed = false;

  @override
  Stream<Uint8List> get output => const Stream.empty();

  @override
  void write(Uint8List bytes) {}

  @override
  void resize(int columns, int rows, int pixelWidth, int pixelHeight) {}

  @override
  Future<int?> get exitCode => Completer<int?>().future;

  @override
  Future<void> close() async => closed = true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deleting a machine ends its shells and closes its open files', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final machines = MachinesProvider(db, SecretStore());
    final dock = DockController(machines);
    final temp = Directory.systemTemp.createTempSync('dock-machine-');
    addTearDown(() async {
      dock.dispose();
      machines.dispose();
      await db.close();
      temp.deleteSync(recursive: true);
    });
    Future<void> until(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final machine = LocalMachine(
      id: 'local',
      name: 'This computer',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );
    await machines.save(machine);
    await until(() => machines.byId('local') != null);

    final backend = _Backend();
    final shell = TerminalSession(title: 'sh', open: (columns, rows) async => backend);
    dock.terminals('local').add(shell);
    shell.terminal.resize(90, 30);
    await until(() => shell.phase is TerminalRunning);

    File('${temp.path}/notes.txt').writeAsStringSync('one\n');
    final workspace = dock.files('local')
      ..connect = () async => (
        LocalLink(),
        HostProbe(
          commandShell: CommandShell.posix,
          os: HostOs.macos,
          kernel: 'Darwin',
          arch: 'arm64',
          home: temp.path,
          agentDir: '${temp.path}/.omp/agent',
        ),
      );
    await workspace.open('${temp.path}/notes.txt');
    workspace.current!.controller.text = 'unsaved\n';

    await machines.delete(machine);
    await until(() => machines.byId('local') == null);
    expect(backend.closed, isTrue);
    expect(workspace.documents, isEmpty);
  });
}
