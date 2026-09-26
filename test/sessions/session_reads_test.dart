import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/database/app_database.dart';
import 'package:ompanion/sessions/session_reads.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

final class _Session implements LiveSession {
  _Session(this.sessionPath);

  @override
  final String? sessionPath;

  final _views = StreamController<SessionView>.broadcast(sync: true);
  SessionView _view = SessionView();

  void emit(SessionView view) {
    _view = view;
    _views.add(view);
  }

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  String get runId => 'run-$sessionPath';

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

SessionSummary _file(String path, int second) => SessionSummary(
  path: path,
  size: 1,
  modified: DateTime.fromMillisecondsSinceEpoch(second * 1000, isUtc: true),
  id: path,
);

SessionView _answered(String text, {bool running = false}) => SessionView(
  run: RunState(running: running),
  transcript: [
    AssistantItem(
      key: 'a-$text',
      timestamp: 1,
      content: [TextBlock(text)],
      provider: 'fake',
      model: 'fake',
      stopReason: StopReason.stop,
    ),
  ],
);

void main() {
  late AppDatabase db;
  final relisted = <String>[];

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    relisted.clear();
  });

  tearDown(() async {
    // Marker writes are not awaited by the tracker.
    await pumpEventQueue();
    await db.close();
  });

  Future<void> insertMachine() => db
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

  Future<SessionReads> reads() async {
    final reads = SessionReads(db, relist: relisted.add);
    await reads.ready;
    return reads;
  }

  test('a file is read when first listed and unread once it changes, across restarts', () async {
    await insertMachine();
    final first = await reads();
    first.update(open: const {}, viewed: null, listings: {'m1': [_file('/a', 10)]});
    expect(first.isListedUnread('m1', _file('/a', 10)), isFalse);

    first.update(open: const {}, viewed: null, listings: {'m1': [_file('/a', 20)]});
    expect(first.isListedUnread('m1', _file('/a', 20)), isTrue);
    first.dispose();

    final restarted = await reads();
    restarted.update(open: const {}, viewed: null, listings: {'m1': [_file('/a', 20)]});
    expect(restarted.isListedUnread('m1', _file('/a', 20)), isTrue);
    restarted.dispose();
  });

  test('an open session is unread after output off screen and read once shown', () async {
    final tracker = await reads();
    final shown = _Session('/shown');
    final other = _Session('/other');
    final open = {shown: 'm1', other: 'm1'};
    tracker.update(open: open, viewed: shown, listings: const {});

    shown.emit(_answered('hi'));
    other.emit(_answered('hello'));
    expect(tracker.isLiveUnread(shown), isFalse);
    expect(tracker.isLiveUnread(other), isTrue);

    tracker.update(open: open, viewed: other, listings: const {});
    expect(tracker.isLiveUnread(other), isFalse);
    tracker.dispose();
  });

  test('a finished run off screen is unread and lists the machine again', () async {
    final tracker = await reads();
    final session = _Session('/s');
    tracker.update(open: {session: 'm1'}, viewed: null, listings: const {});
    session.emit(SessionView(run: const RunState(running: true)));
    expect(tracker.isLiveUnread(session), isFalse);

    session.emit(SessionView());
    expect(tracker.isLiveUnread(session), isTrue);
    expect(relisted, ['m1']);
    tracker.dispose();
  });

  test('seeded history is not news', () async {
    final tracker = await reads();
    final session = _Session('/s');
    tracker.update(open: {session: 'm1'}, viewed: null, listings: const {});
    final seeded = _answered('old');
    session.emit(seeded.copyWith(historyLength: seeded.transcript.length));
    expect(tracker.isLiveUnread(session), isFalse);
    tracker.dispose();
  });

  test('a session closed while read stays read through writes the listing had not seen', () async {
    await insertMachine();
    final tracker = await reads();
    final session = _Session('/s');
    final listing = [_file('/s', 10)];
    tracker.update(open: {session: 'm1'}, viewed: session, listings: {'m1': listing});

    // Output while on screen, then the session closes; the file's time moved past the last listing.
    session.emit(_answered('done'));
    tracker.update(open: const {}, viewed: null, listings: {'m1': listing});
    expect(relisted, ['m1']);
    tracker.update(open: const {}, viewed: null, listings: {'m1': [_file('/s', 15)]});
    expect(tracker.isListedUnread('m1', _file('/s', 15)), isFalse);

    // Later writes by another device are news again.
    tracker.update(open: const {}, viewed: null, listings: {'m1': [_file('/s', 30)]});
    expect(tracker.isListedUnread('m1', _file('/s', 30)), isTrue);
    tracker.dispose();
  });

  test('a session closed with unseen output stays unread', () async {
    await insertMachine();
    final tracker = await reads();
    final session = _Session('/s');
    tracker.update(open: {session: 'm1'}, viewed: null, listings: {'m1': [_file('/s', 10)]});

    session.emit(_answered('done'));
    tracker.update(open: const {}, viewed: null, listings: {'m1': [_file('/s', 15)]});
    expect(tracker.isListedUnread('m1', _file('/s', 15)), isTrue);
    tracker.dispose();
  });
}
