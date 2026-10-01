import 'dart:async';

import 'package:drift/drift.dart' show InsertMode;
import 'package:flutter/foundation.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';

import '../database/app_database.dart';
import '../providers/machines_provider.dart';
import '../providers/shell_provider.dart';
import 'sessions_provider.dart';

typedef _FileKey = (String machineId, String path);

/// Which sessions have news the user has not seen: a run that finished, or new assistant output, since the
/// session was last on screen.
///
/// A session open on this device is tracked live from its views. Any other session compares its file's
/// modification time in the machine's listing with a persisted marker: the modification time up to which it was
/// read. Markers use the machine's clock only, so skew between devices does not matter. A file listed for the
/// first time gets a marker at its current time: history from before this device saw it is not news.
class SessionReads extends ChangeNotifier {
  /// [relist] lists a machine's sessions again; the listing's modification times are the markers' clock.
  SessionReads(this._db, {required this._relist}) {
    _ready = _load();
  }

  /// Tracks what [sessions] has open and lists, and what [shell] shows.
  factory SessionReads.following(
    AppDatabase db, {
    required SessionsProvider sessions,
    required ShellProvider shell,
    required MachinesProvider machines,
  }) {
    final reads = SessionReads(
      db,
      relist: (machineId) {
        final machine = machines.byId(machineId);
        if (machine != null) unawaited(sessions.refresh(machine));
      },
    );
    void sync() => reads.update(
      open: {
        for (final session in sessions.openSessions)
          if (sessions.machineOf(session) case final machine?) session: machine.id,
      },
      viewed: shell.selection is SessionSelection ? sessions.active : null,
      listings: {
        for (final machine in machines.machines)
          if (sessions.listingOf(machine) case SessionListing(loadedAt: _?, :final sessions)) machine.id: sessions,
      },
    );
    sessions.addListener(sync);
    shell.addListener(sync);
    reads._unfollow = () {
      sessions.removeListener(sync);
      shell.removeListener(sync);
    };
    sync();
    return reads;
  }

  final AppDatabase _db;
  final void Function(String machineId) _relist;
  VoidCallback? _unfollow;

  final Map<_FileKey, DateTime> _markers = {};
  late final Future<void> _ready;
  bool _loaded = false;

  final Map<LiveSession, _Watch> _live = {};
  LiveSession? _viewed;

  /// Files of sessions that closed here while read: the next listing marks them read up to its time.
  final Set<_FileKey> _closedRead = {};

  /// The listing of each machine last applied to the markers.
  final Map<String, List<SessionSummary>> _applied = {};
  Map<String, List<SessionSummary>> _listings = const {};
  bool _disposed = false;

  /// Resolves once the persisted markers are loaded; listings apply from then on.
  Future<void> get ready => _ready;

  Future<void> _load() async {
    for (final row in await _db.select(_db.readMarkers).get()) {
      _markers[(row.machineId, row.path)] = row.seenModified;
    }
    if (_disposed) return;
    _loaded = true;
    notifyListeners();
    _applyListings();
  }

  /// Whether [session] got a finished run or new assistant output while it was not on screen.
  bool isLiveUnread(LiveSession session) => _live[session]?.unread ?? false;

  /// Whether [summary]'s file on [machineId] changed since it was last read.
  bool isListedUnread(String machineId, SessionSummary summary) {
    final marker = _markers[(machineId, summary.path)];
    return marker != null && summary.modified.isAfter(marker);
  }

  /// Marks [live], sessions open on this device, read, and [listed], files on [machineId], read up to their listed
  /// modification times; later writes are news again.
  void markRead(String machineId, {Iterable<SessionSummary> listed = const [], Iterable<LiveSession> live = const []}) {
    if (_disposed) return;
    var changed = false;
    for (final session in live) {
      final watch = _live[session];
      if (watch == null || !watch.unread) continue;
      watch.unread = false;
      changed = true;
    }
    // Only files with a marker can be unread, so nothing is written before the persisted markers load.
    final updates = <_FileKey, DateTime>{
      for (final summary in listed)
        if (isListedUnread(machineId, summary)) (machineId, summary.path): summary.modified,
    };
    if (updates.isNotEmpty) _advance(updates);
    if (changed || updates.isNotEmpty) notifyListeners();
  }

  /// Takes the sessions open on this device with their machine ids, the one on screen, and each machine's latest
  /// listing. Opening a session shows it, which marks it read.
  void update({
    required Map<LiveSession, String> open,
    required LiveSession? viewed,
    required Map<String, List<SessionSummary>> listings,
  }) {
    if (_disposed) return;
    var changed = false;
    final gone = [
      for (final entry in _live.entries)
        if (!open.containsKey(entry.key)) entry,
    ];
    final relist = <String>{};
    for (final MapEntry(key: session, value: watch) in gone) {
      _live.remove(session);
      unawaited(watch.subscription.cancel());
      final path = session.sessionPath;
      if (!watch.unread && path != null) {
        _closedRead.add((watch.machineId, path));
        relist.add(watch.machineId);
      }
    }
    for (final MapEntry(key: session, value: machineId) in open.entries) {
      if (_live.containsKey(session)) continue;
      // A session reopened in place of one with unseen news keeps them.
      final path = session.sessionPath;
      final replaced = path != null && gone.any((entry) => entry.value.unread && entry.key.sessionPath == path);
      _live[session] = _Watch(
        machineId: machineId,
        view: session.view,
        unread: replaced,
        subscription: session.views.listen((view) => _onView(session, view)),
      );
      changed = changed || replaced;
    }
    _viewed = viewed;
    final watch = viewed == null ? null : _live[viewed];
    if (watch != null && watch.unread) {
      watch.unread = false;
      changed = true;
    }
    _listings = listings;
    _applyListings();
    if (changed) notifyListeners();
    // Last: a relist notifies, which may call this again.
    relist.forEach(_relist);
  }

  void _onView(LiveSession session, SessionView view) {
    final watch = _live[session];
    if (watch == null) return;
    final before = watch.view;
    watch.view = view;
    final finished = before.run.running && !view.run.running;
    // A read session's marker catches up with the listing that follows its run.
    if (finished) _relist(watch.machineId);
    if (watch.unread || identical(_viewed, session)) return;
    if (finished || _newAssistantOutput(before, view)) {
      watch.unread = true;
      notifyListeners();
    }
  }

  /// A transcript that ends in an assistant message it did not end in before, or one that grew; seeded rows (opening,
  /// resyncing) are history, not news.
  static bool _newAssistantOutput(SessionView before, SessionView after) {
    final last = after.transcript.lastOrNull;
    if (last is! AssistantItem || after.transcript.length <= after.historyLength) return false;
    final previous = before.transcript.lastOrNull;
    return previous is! AssistantItem || previous.key != last.key || !identical(previous.content, last.content);
  }

  void _applyListings() {
    if (!_loaded || _disposed) return;
    final updates = <_FileKey, DateTime>{};
    for (final MapEntry(key: machineId, value: summaries) in _listings.entries) {
      if (identical(_applied[machineId], summaries)) continue;
      _applied[machineId] = summaries;
      for (final summary in summaries) {
        final key = (machineId, summary.path);
        final marker = _markers[key];
        final live = _live.entries
            .where((entry) => entry.value.machineId == machineId && SessionsProvider.holds(entry.key, summary))
            .firstOrNull;
        final read = _closedRead.contains(key) || (live != null && !live.value.unread);
        if (marker == null || (read && summary.modified.isAfter(marker))) updates[key] = summary.modified;
      }
      _closedRead.removeWhere((key) => key.$1 == machineId);
    }
    if (updates.isEmpty) return;
    _advance(updates);
    notifyListeners();
  }

  /// Moves the markers in [updates] to their times and persists them.
  void _advance(Map<_FileKey, DateTime> updates) {
    _markers.addAll(updates);
    unawaited(
      _db.batch((batch) {
        for (final MapEntry(key: (machineId, path), value: seen) in updates.entries) {
          batch.insert(
            _db.readMarkers,
            ReadMarkersCompanion.insert(machineId: machineId, path: path, seenModified: seen),
            mode: InsertMode.insertOrReplace,
          );
        }
      }),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _unfollow?.call();
    for (final watch in _live.values) {
      unawaited(watch.subscription.cancel());
    }
    _live.clear();
    super.dispose();
  }
}

final class _Watch {
  _Watch({required this.machineId, required this.view, required this.unread, required this.subscription});

  final String machineId;
  SessionView view;
  bool unread;
  final StreamSubscription<SessionView> subscription;
}
