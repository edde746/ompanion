import 'dart:async';

import 'package:drift/drift.dart';
import 'package:flutter/foundation.dart';
import 'package:omp_core/host.dart';

import '../database/app_database.dart';
import '../providers/machines_provider.dart';
import 'sessions_provider.dart';

/// The sessions pinned above the machines in the sidebar, from any machine, in the order they were pinned. A machine's
/// listing brings the stored path, directory and title of its pins up to date, so a pin shows and opens as it last was
/// while its machine is not listed. A deleted machine takes its pins with it (the table's foreign key).
class SessionPins extends ChangeNotifier {
  SessionPins(this._db) {
    _ready = _load();
  }

  /// Keeps the pins in step with the listings of [sessions].
  factory SessionPins.following(
    AppDatabase db, {
    required SessionsProvider sessions,
    required MachinesProvider machines,
  }) {
    final pins = SessionPins(db);
    void sync() => pins.update(
      listings: {
        for (final machine in machines.machines)
          if (sessions.listingOf(machine) case SessionListing(loadedAt: _?, :final sessions)) machine.id: sessions,
      },
    );
    sessions.addListener(sync);
    pins._unfollow = () => sessions.removeListener(sync);
    sync();
    return pins;
  }

  final AppDatabase _db;
  VoidCallback? _unfollow;
  late final Future<void> _ready;
  bool _loaded = false;
  bool _disposed = false;

  List<PinnedSessionRow> _pins = const [];

  /// The listing of each machine last applied to the pins.
  final Map<String, List<SessionSummary>> _applied = {};
  Map<String, List<SessionSummary>> _listings = const {};

  /// Resolves once the stored pins are loaded.
  Future<void> get ready => _ready;

  /// Oldest pin first.
  List<PinnedSessionRow> get pins => _pins;

  bool isPinned(String machineId, String sessionId) =>
      _pins.any((pin) => pin.machineId == machineId && pin.sessionId == sessionId);

  Future<void> _load() async {
    final rows = await (_db.select(_db.pinnedSessions)..orderBy([(pin) => OrderingTerm.asc(pin.pinnedAt)])).get();
    if (_disposed) return;
    _pins = List.unmodifiable(rows);
    _loaded = true;
    notifyListeners();
    _applyListings();
  }

  /// Pins a session, after the ones pinned before; pinning it again changes nothing.
  Future<void> pin(PinnedSessionRow pin) async {
    await _ready;
    if (_disposed || isPinned(pin.machineId, pin.sessionId)) return;
    _pins = List.unmodifiable([..._pins, pin]);
    notifyListeners();
    await _db.into(_db.pinnedSessions).insert(pin, mode: InsertMode.insertOrReplace);
  }

  Future<void> unpin(String machineId, String sessionId) async {
    await _ready;
    if (_disposed || !isPinned(machineId, sessionId)) return;
    _pins = List.unmodifiable(_pins.where((pin) => pin.machineId != machineId || pin.sessionId != sessionId));
    notifyListeners();
    await (_db.delete(
      _db.pinnedSessions,
    )..where((pin) => pin.machineId.equals(machineId) & pin.sessionId.equals(sessionId))).go();
  }

  /// Unpins [pin]'s session when it is pinned, else pins it.
  Future<void> toggle(PinnedSessionRow pin) =>
      isPinned(pin.machineId, pin.sessionId) ? unpin(pin.machineId, pin.sessionId) : this.pin(pin);

  /// Takes each machine's latest listing.
  void update({required Map<String, List<SessionSummary>> listings}) {
    if (_disposed) return;
    _listings = listings;
    _applyListings();
  }

  void _applyListings() {
    if (!_loaded || _disposed) return;
    final updated = <PinnedSessionRow>[];
    for (final MapEntry(key: machineId, value: summaries) in _listings.entries) {
      if (identical(_applied[machineId], summaries)) continue;
      _applied[machineId] = summaries;
      for (final pin in _pins) {
        if (pin.machineId != machineId) continue;
        final summary = summaries.where((summary) => summary.id == pin.sessionId).firstOrNull;
        if (summary == null) continue;
        final fresh = pin.copyWith(
          path: summary.path,
          cwd: summary.cwd ?? pin.cwd,
          title: Value(summary.title),
          firstMessage: Value(summary.firstMessage),
        );
        if (fresh != pin) updated.add(fresh);
      }
    }
    if (updated.isEmpty) return;
    _pins = List.unmodifiable([
      for (final pin in _pins)
        updated.where((fresh) => fresh.machineId == pin.machineId && fresh.sessionId == pin.sessionId).firstOrNull ??
            pin,
    ]);
    notifyListeners();
    unawaited(
      _db.batch((batch) {
        for (final pin in updated) {
          batch.insert(_db.pinnedSessions, pin, mode: InsertMode.insertOrReplace);
        }
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _unfollow?.call();
    super.dispose();
  }
}
