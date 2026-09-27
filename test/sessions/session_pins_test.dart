import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:omp_core/host.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/sessions/session_pins.dart';

PinnedSessionRow _pin(String sessionId, {int minute = 0}) => PinnedSessionRow(
  machineId: 'm1',
  sessionId: sessionId,
  path: '/home/me/.omp/sessions/$sessionId.jsonl',
  cwd: '/home/me/app',
  title: 'Old title of $sessionId',
  pinnedAt: DateTime.utc(2026, 9, 27, 10, minute),
);

void main() {
  late AppDatabase db;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db
        .into(db.machines)
        .insert(
          MachinesCompanion.insert(
            id: 'm1',
            name: 'box',
            kind: MachineKind.local,
            createdAt: DateTime.utc(2026),
            updatedAt: DateTime.utc(2026),
          ),
        );
  });

  tearDown(() => db.close());

  Future<SessionPins> load() async {
    final pins = SessionPins(db);
    await pins.ready;
    return pins;
  }

  test('pins keep their order across restarts, pinning twice changes nothing, and a toggle unpins', () async {
    final pins = await load();
    await pins.pin(_pin('b', minute: 1));
    await pins.pin(_pin('a', minute: 2));
    await pins.pin(_pin('b', minute: 3));
    expect([for (final pin in pins.pins) pin.sessionId], ['b', 'a']);
    pins.dispose();

    final again = await load();
    expect([for (final pin in again.pins) pin.sessionId], ['b', 'a']);
    await again.toggle(_pin('b'));
    expect(again.isPinned('m1', 'b'), isFalse);
    again.dispose();
    expect([for (final pin in (await load()).pins) pin.sessionId], ['a']);
  });

  test('a listing brings a pin up to date: its file after a move, its title, its first message', () async {
    final pins = await load();
    await pins.pin(_pin('a'));
    await pins.pin(_pin('b', minute: 1));
    pins.update(
      listings: {
        'm1': [
          SessionSummary(
            path: '/home/me/.omp/sessions/moved/a.jsonl',
            size: 1,
            modified: DateTime.utc(2026, 9, 27),
            id: 'a',
            cwd: '/home/me/moved',
            title: 'New title',
            firstMessage: 'Hello',
          ),
        ],
      },
    );
    final fresh = pins.pins.first;
    expect(
      (fresh.path, fresh.cwd, fresh.title, fresh.firstMessage),
      ('/home/me/.omp/sessions/moved/a.jsonl', '/home/me/moved', 'New title', 'Hello'),
    );
    // Not listed: kept as stored.
    expect(pins.pins.last, _pin('b', minute: 1));
    pins.dispose();

    final again = await load();
    expect(again.pins.first.path, '/home/me/.omp/sessions/moved/a.jsonl');
    again.dispose();
  });
}
