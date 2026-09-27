import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import '../companion/companion_client.dart';
import '../host/probe.dart';
import '../host/session_writer.dart';
import '../rpc/rpc_client.dart';
import '../store/external_writer.dart';
import '../store/reducer.dart' as store show dismissNotice;
import '../store/reducer.dart' show withEntries;
import '../store/session_view.dart';
import '../transport/host_link.dart';
import 'live_session.dart';
import 'run_session.dart' show sessionFileEntries;

/// A session file another omp process is writing, as the app sees it: the app reads the file and never starts its
/// own omp for it. Two writers appending to one session file interleave their turns, and each one's later rewrite
/// drops the other's entries, so a session another process holds cannot be driven from here.
///
/// The view comes from the file alone: the entries read so far, reduced with the same transcript rules as a run
/// (`withEntries`), plus what the machine says about the writer ([SessionView.external]). There is no RPC and no
/// companion here, so the model, the queue, the open dialogs and everything else that lives in the other process
/// are unknown; the transcript and the writer state are what the app can honestly show.
final class ExternalSession implements LiveSession {
  /// [writer] is what the probe that sent the app here found.
  ExternalSession({
    required this.sessionPath,
    required this.cwd,
    required this.link,
    required this.probe,
    required this._writer,
    this.pollInterval = const Duration(seconds: 2),
    this.pagedHistoryFrom = 16 << 20,
    this.historyPageBytes = 2 << 20,
  });

  @override
  final String sessionPath;

  /// The session's directory, from the listing; the file's own header is read for the title only.
  @override
  final String cwd;

  /// The machine, and its probe, the session file is read from.
  final HostLink link;
  final HostProbe probe;

  /// How often the file and the machine are looked at while the session is open.
  final Duration pollInterval;

  /// A session file larger than this opens with its last [historyPageBytes] only, as a run's does; [loadEarlier]
  /// reads the pages before.
  final int pagedHistoryFrom;
  final int historyPageBytes;

  /// Called once, when the session reaches [LinkClosed].
  void Function()? onClosed;

  static const _readOnly = 'another omp process writes this session; ompanion only reads its file';

  /// Link failures this session tolerates before it gives up: a dropped link is worth retrying, a file that
  /// stayed unreadable is not.
  static const _failuresBeforeClosed = 3;

  /// Bytes before the end of the last read that are compared on the next one: omp rewrites a session file by
  /// replacing it (compaction of its own state, a moved workspace), and a rewrite that grew the file must not be
  /// read as an append.
  static const _tailBytes = 64;

  /// The head holding the title slot (a fixed-width first line) and the session header.
  static const _headBytes = 4096;

  final _views = StreamController<SessionView>.broadcast();
  final _linkStates = StreamController<LinkState>.broadcast();
  final _entries = <Map<String, Object?>>[];

  HostFiles? _files;
  SessionView _view = SessionView();
  LinkState _linkState = const LinkLive();
  ExternalWriter? _writer;
  String? _title;

  /// Where the first line [_entries] hold starts; 0 once the whole file is read.
  int _historyFrom = 0;

  /// Just past the last complete line read. A line omp is still writing is read whole on the next change.
  int _end = 0;

  /// The bytes up to [_end] as last read; empty until a read succeeded, which makes the next one start afresh.
  Uint8List _tail = Uint8List(0);

  /// The file's size and modification time at the last read: a change of either is a change of the file.
  int? _size;
  DateTime? _modified;

  int _failures = 0;
  Timer? _timer;
  bool _polling = false;
  bool _loadingEarlier = false;
  bool _closed = false;

  @override
  String get runId => 'file:${sessionPath.split('/').last}';

  @override
  SessionView get view => _view;

  @override
  Stream<SessionView> get views => _views.stream;

  @override
  LinkState get linkState => _linkState;

  @override
  Stream<LinkState> get linkStates => _linkStates.stream;

  /// Nothing here commands the other process: every call that would is refused, so a caller that slipped through
  /// fails loudly instead of writing to a session the app does not own.
  @override
  RpcClient get rpc => throw UnsupportedError(_readOnly);

  @override
  CompanionClient get companion => throw UnsupportedError(_readOnly);

  /// The other process has no companion the app can reach.
  @override
  CompanionHello? get companionHello => null;

  @override
  Future<void> Function()? get loadEarlier => _historyFrom > 0 && !_closed ? _loadEarlier : null;

  /// Reads the file and starts watching it. Throws when the file cannot be read; the session is closed then.
  Future<void> start() async {
    try {
      final files = _files = await link.files();
      final stat = await files.stat(sessionPath);
      if (stat != null) await _read(files, stat);
      _setView(_view.copyWith(external: _external()));
    } on Object catch (error) {
      _finish(LinkClosed(cause: error));
      rethrow;
    }
    _timer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
  }

  /// One look at the file and the machine: what the file appended, its title, and who writes it.
  Future<void> poll() async {
    final files = _files;
    if (_closed || _polling || files == null) return;
    _polling = true;
    try {
      final stat = await files.stat(sessionPath);
      if (stat != null && (stat.size != _size || stat.modified != _modified)) await _read(files, stat);
      _writer = await probeSessionWriter(link, probe, sessionPath);
      final external = _external();
      if (external != _view.external) _setView(_view.copyWith(external: external));
      _failures = 0;
    } on Object catch (error) {
      if (++_failures >= _failuresBeforeClosed) {
        _finish(LinkClosed(cause: error));
        return;
      }
      _warn('Reading the session file failed: $error');
    } finally {
      _polling = false;
    }
  }

  /// Never reconnecting: the session reads the file over the link it was opened on, and closes when that fails.
  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async => _finish(const LinkClosed());

  @override
  Future<void> stop() async => throw UnsupportedError(_readOnly);

  @override
  void dismissRequest(String id) {}

  /// Nothing here waits for a reply: a prompt cannot be sent from this session.
  @override
  void setPromptPending(bool pending) {}

  @override
  void dismissNotice(int seq) => _setView(store.dismissNotice(_view, seq));

  /// The writer as the view shows it: busy while the file's last message leaves a turn open.
  ExternalWriter? _external() => _writer?.copyWith(busy: turnInFlight(_entries));

  /// Reads what changed: the lines appended since the last read when the bytes before its end are still there,
  /// else the file's latest page afresh (it shrank or was replaced). The head is read again for the title, which
  /// omp rewrites in place.
  Future<void> _read(HostFiles files, HostFileStat stat) async {
    _size = stat.size;
    _modified = stat.modified;
    if (!await _readAppended(files, stat.size)) {
      final page = await _readPage(files, stat.size > pagedHistoryFrom ? stat.size - historyPageBytes : 0, stat.size);
      _tail = Uint8List(0);
      if (page == null) {
        _warn('A line of the session file is not JSON');
        return;
      }
      _entries
        ..clear()
        ..addAll(page.entries);
      _historyFrom = page.from;
      _end = page.from;
      _consumed(page.bytes, page.from);
    }
    _title = _readTitle(await files.read(sessionPath, length: _headBytes)) ?? _title;
    _entriesChanged();
  }

  /// Adds the entries on the lines after [_end]. False when the bytes before [_end] changed (the file shrank or was
  /// replaced) or an appended line is not JSON.
  Future<bool> _readAppended(HostFiles files, int size) async {
    final tail = _tail;
    if (tail.isEmpty || size < _end) return false;
    final from = _end - tail.length;
    final bytes = await files.read(sessionPath, offset: from, length: size - from);
    if (!_startsWith(bytes, tail)) return false;
    final appended = Uint8List.sublistView(bytes, tail.length);
    final entries = await _parse(appended);
    if (entries == null) return false;
    _entries.addAll(entries);
    _consumed(appended, _end);
    return true;
  }

  /// Records [bytes], read from [offset], as read up to their last complete line.
  void _consumed(Uint8List bytes, int offset) {
    final complete = bytes.lastIndexOf(0x0A) + 1;
    if (complete == 0) return;
    _end = offset + complete;
    _tail = Uint8List.fromList(bytes.sublist(max(0, complete - _tailBytes), complete));
  }

  Future<void> _loadEarlier() async {
    final files = _files;
    final to = _historyFrom;
    if (_loadingEarlier || files == null || to == 0) return;
    _loadingEarlier = true;
    try {
      final page = await _readPage(files, max(0, to - historyPageBytes), to);
      if (page == null) throw FormatException('a line of $sessionPath is not JSON');
      // A read afresh (the file was rewritten) replaced the entries meanwhile.
      if (_closed || _historyFrom != to) return;
      _historyFrom = page.from;
      _entries.insertAll(0, page.entries);
      _entriesChanged();
    } on Object catch (error) {
      _warn('Loading earlier messages failed: $error');
    } finally {
      _loadingEarlier = false;
    }
  }

  /// The entries on the complete lines between [from] and [to]. The line [from] falls inside of is left to the page
  /// before, and the page grows until it holds a line start. Null when a line is not JSON.
  Future<({List<Map<String, Object?>> entries, Uint8List bytes, int from})?> _readPage(
    HostFiles files,
    int from,
    int to,
  ) async {
    var start = from;
    for (;;) {
      final bytes = await files.read(sessionPath, offset: start, length: to - start);
      final skip = start == 0 ? 0 : bytes.indexOf(0x0A) + 1;
      if (start > 0 && skip == 0) {
        start = max(0, start - (to - start));
        continue;
      }
      final lines = Uint8List.sublistView(bytes, skip);
      final entries = await _parse(lines);
      return entries == null ? null : (entries: entries, bytes: lines, from: start + skip);
    }
  }

  static Future<List<Map<String, Object?>>?> _parse(Uint8List bytes) async =>
      bytes.length > 64 * 1024 ? await Isolate.run(() => sessionFileEntries(bytes)) : sessionFileEntries(bytes);

  static bool _startsWith(Uint8List bytes, Uint8List prefix) {
    if (bytes.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (bytes[i] != prefix[i]) return false;
    }
    return true;
  }

  /// The title the file's head records: the fixed-width title slot on the first line, else the session header's
  /// `title` on the second (`session.md`, `session-title-slot.ts`).
  static String? _readTitle(Uint8List bytes) {
    final head = bytes.sublist(0, min(bytes.length, _headBytes));
    String? title;
    for (final line in const LineSplitter().convert(utf8.decode(head, allowMalformed: true)).take(2)) {
      final Object? decoded;
      try {
        decoded = jsonDecode(line);
      } on FormatException {
        continue;
      }
      if (decoded is! Map<String, Object?>) continue;
      if (decoded['title'] case final String value) title ??= value;
    }
    return title;
  }

  /// Rebuilds the transcript from the entries read so far; the leaf is the last one the file appended. An entry the
  /// reducer cannot decode is reported and leaves the transcript as it was: the file is still readable, so it does not
  /// count as a failed look.
  void _entriesChanged() {
    final base = SessionView(
      config: SessionConfig(sessionFile: sessionPath, sessionName: _title),
      notices: _view.notices,
      nextSeq: _view.nextSeq,
      external: _external(),
    );
    final last = _entries.isEmpty ? null : _entries.last['id'];
    try {
      _setView(withEntries(base, _entries, leafId: last is String ? last : null));
    } on FormatException catch (error) {
      _warn('A session file entry is malformed: ${error.message}');
    }
  }

  void _warn(String message) {
    final notices = [
      ..._view.notices,
      MessageNotice(_view.nextSeq, level: NoticeLevel.warning, message: message, source: 'ompanion'),
    ];
    _setView(
      _view.copyWith(
        notices: UnmodifiableListView(notices.sublist(max(0, notices.length - SessionView.maxNotices))),
        nextSeq: _view.nextSeq + 1,
      ),
    );
  }

  void _finish(LinkClosed state) {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    final files = _files;
    _files = null;
    if (files != null) unawaited(files.close());
    _linkState = state;
    if (!_linkStates.isClosed) _linkStates.add(state);
    unawaited(_views.close());
    unawaited(_linkStates.close());
    onClosed?.call();
  }

  void _setView(SessionView view) {
    _view = view;
    if (!_views.isClosed) _views.add(view);
  }
}
