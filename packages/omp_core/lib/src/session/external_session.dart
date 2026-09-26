import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../companion/companion_client.dart';
import '../host/probe.dart';
import '../host/session_writer.dart';
import '../rpc/rpc_client.dart';
import '../store/external_writer.dart';
import '../store/reducer.dart';
import '../store/session_view.dart';
import '../transport/host_link.dart';
import 'live_session.dart';
import 'run_session.dart' show sessionFileEntries;

/// A session file another omp process is writing, as the app sees it: the app reads the file and never starts its
/// own omp for it. Two writers appending to one session file interleave their turns, and each one's later rewrite
/// drops the other's entries, so a session another process holds cannot be driven from here.
///
/// The view comes from the file alone: every entry the file holds, reduced with the same transcript rules as a run
/// (`withEntries`), plus what the machine says about the writer ([SessionView.external]). There is no RPC and no
/// companion here, so the model, the queue, the open dialogs and everything else that lives in the other process
/// are unknown; the transcript and the writer state are what the app can honestly show.
final class ExternalSession implements LiveSession {
  ExternalSession({
    required this.sessionPath,
    required this.cwd,
    required this.link,
    required this.probe,
    this.pollInterval = const Duration(seconds: 2),
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

  static const _readOnly = 'another omp process writes this session; ompanion only reads its file';

  /// Link failures this session tolerates before it gives up: a dropped link is worth retrying, a file that
  /// stayed unreadable is not.
  static const _failuresBeforeClosed = 3;

  final _views = StreamController<SessionView>.broadcast();
  final _linkStates = StreamController<LinkState>.broadcast();
  final _notices = <Notice>[];

  HostFiles? _files;
  SessionView _view = SessionView();
  LinkState _linkState = const LinkLive();
  List<Map<String, Object?>> _entries = const [];
  ExternalWriter? _writer;
  String? _title;
  int _size = 0;
  DateTime? _modified;
  DateTime? _changedAt;
  int _nextSeq = 0;
  int _failures = 0;
  Timer? _timer;
  bool _polling = false;
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

  /// The whole file is loaded, so no earlier page is unread.
  @override
  Future<void> Function()? get loadEarlier => null;

  /// Reads the file once and starts watching it.
  Future<void> start() async {
    _files = await link.files();
    await _read(full: true);
    // A held descriptor on the first look means a turn is running now; there is no earlier look to compare with.
    _writer = polledWriter(
      probed: await probeSessionWriter(link, probe, sessionPath),
      changed: false,
      quietFor: Duration.zero,
    );
    _changedAt = DateTime.now();
    _setView(_build());
    _timer = Timer.periodic(pollInterval, (_) => unawaited(poll()));
  }

  /// One look at the machine and the file: the entries the file appended, its head's title, and who writes it.
  Future<void> poll() async {
    if (_closed || _polling) return;
    _polling = true;
    try {
      final files = _files;
      if (files == null) return;
      final stat = await files.stat(sessionPath);
      final changed = stat != null && (stat.size != _size || stat.modified != _modified);
      if (changed) {
        _changedAt = DateTime.now();
        await _read(stat: stat);
      }
      final writer = await probeSessionWriter(link, probe, sessionPath);
      final quietFor = _changedAt == null ? Duration.zero : DateTime.now().difference(_changedAt!);
      _setWriter(polledWriter(probed: writer, changed: changed, quietFor: quietFor));
      _failures = 0;
    } on Object catch (error) {
      if (++_failures >= _failuresBeforeClosed) {
        _timer?.cancel();
        _setLinkState(LinkClosed(cause: error));
        return;
      }
      _warn('Reading the session file failed: $error');
    } finally {
      _polling = false;
    }
  }

  @override
  void reconnectNow() => unawaited(poll());

  @override
  Future<void> detach() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _setLinkState(const LinkClosed());
    final files = _files;
    _files = null;
    await files?.close();
    await _views.close();
    await _linkStates.close();
  }

  @override
  Future<void> stop() async => throw UnsupportedError(_readOnly);

  @override
  void dismissRequest(String id) {}

  /// Nothing here waits for a reply: a prompt cannot be sent from this session.
  @override
  void setPromptPending(bool pending) {}

  @override
  void dismissNotice(int seq) {
    final before = _notices.length;
    _notices.removeWhere((notice) => notice.seq == seq);
    if (_notices.length != before) _setView(_build());
  }

  /// Reads the file, whole when [full] or when the file shrank or was rewritten in place (omp replaces the title
  /// slot at the head without changing the size), and appends only what grew. A file that is not there yet (the
  /// other process has not written its first line) reads as an empty view, not an error.
  Future<void> _read({bool full = false, HostFileStat? stat}) async {
    final files = _files;
    if (files == null) return;
    final current = stat ?? await files.stat(sessionPath);
    if (current == null) {
      if (_size == 0 && _entries.isEmpty) return;
      _size = 0;
      _entries = const [];
      _modified = null;
      _setView(_build());
      return;
    }
    final appended = _size > 0 && current.size > _size && !full;
    final from = appended ? _size : 0;
    final bytes = appended
        ? await files.read(sessionPath, offset: from, length: current.size - from)
        : await files.read(sessionPath, length: current.size);
    if (from == 0) _title = _readTitle(bytes) ?? _title;
    final entries = bytes.length > 64 * 1024
        ? await Isolate.run(() => sessionFileEntries(bytes))
        : sessionFileEntries(bytes);
    if (entries == null) {
      _warn('A line of the session file is not JSON');
      return;
    }
    _entries = from == 0 ? entries : [..._entries, ...entries];
    _size = from + bytes.length;
    _modified = current.modified;
    _setView(_build());
  }

  /// The title the file's head records: the fixed-width title slot on the first line, else the session header's
  /// `title` on the second (`session.md`, `session-title-slot.ts`).
  static String? _readTitle(Uint8List bytes) {
    final head = bytes.sublist(0, bytes.length > 4096 ? 4096 : bytes.length);
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

  /// Rebuilds the view from every entry the file holds, plus the state of the writer.
  SessionView _build() {
    final base = SessionView(
      config: SessionConfig(sessionFile: sessionPath, sessionName: _title),
      notices: UnmodifiableListView(
        _notices.length <= SessionView.maxNotices
            ? _notices
            : _notices.sublist(_notices.length - SessionView.maxNotices),
      ),
      nextSeq: _nextSeq,
      external: _writer,
    );
    final last = _entries.isEmpty ? null : _entries.last['id'];
    return withEntries(base, _entries, leafId: last is String ? last : null);
  }

  void _setWriter(ExternalWriter? writer) {
    final before = _writer;
    // The view carries the writer, so a poll that only changes `busy` or `idleFor` must still reach the UI.
    if (before != null &&
        writer != null &&
        _same(before.pids, writer.pids) &&
        before.terminal == writer.terminal &&
        before.busy == writer.busy &&
        before.idleFor == writer.idleFor) {
      return;
    }
    if (before == null && writer == null) return;
    _writer = writer;
    _setView(_build());
  }

  static bool _same(List<int> a, List<int> b) =>
      a.length == b.length && [for (var i = 0; i < a.length; i++) a[i] == b[i]].every((same) => same);

  void _warn(String message) {
    _notices.add(MessageNotice(_nextSeq++, level: NoticeLevel.warning, message: message, source: 'ompanion'));
    _setView(_build());
  }

  void _setView(SessionView view) {
    _view = view;
    if (!_views.isClosed) _views.add(view);
  }

  void _setLinkState(LinkState state) {
    _linkState = state;
    if (!_linkStates.isClosed) _linkStates.add(state);
  }
}
