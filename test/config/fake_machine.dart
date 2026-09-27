import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/models/machine.dart';
import 'package:ompanion/sessions/sessions_provider.dart';
import 'package:omp_core/companion.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

/// What the companion answers to [verb] called with [args].
typedef CompanionReply = Object? Function(String verb, Map<String, Object?> args);

/// An omp that accepts every command and answers each `/ompx` call with [reply]. `login` stays pending.
final class FakeOmp implements LineChannel {
  FakeOmp(this.reply);

  final CompanionReply reply;
  final _lines = StreamController<String>();

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async {
    final json = jsonDecode(line) as Map<String, Object?>;
    final id = json['id'];
    if (id == null || json['type'] == 'login') return;
    scheduleMicrotask(() {
      final data = json['type'] == 'negotiate_protocol' ? {'protocolVersion': 2} : null;
      _lines.add(jsonEncode({'type': 'response', 'id': id, 'command': json['type'], 'success': true, 'data': ?data}));
      if (json case {'type': 'prompt', 'message': final String message} when message.startsWith('/ompx ')) {
        final call = jsonDecode(message.substring('/ompx '.length)) as Map<String, Object?>;
        final result = reply(call['verb']! as String, call['args']! as Map<String, Object?>);
        emit({'kind': 'reply', 'callId': call['callId'], 'ok': true, 'result': result});
      }
    });
  }

  /// Writes an `ompx` frame: a `reply`, an `event` or a `request`.
  void emit(Map<String, Object?> frame) => _lines.add(jsonEncode({'type': 'ompx', ...frame}));

  @override
  Future<void> close() async => _lines.close();
}

/// A live session over a [FakeOmp]. Call [attach] before using it.
final class FakeSession implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  FakeSession({this.cwd = '/home/u', this.runId = 'control', CompanionReply? reply})
    : omp = FakeOmp(reply ?? (verb, _) => throw StateError('unexpected companion call $verb')) {
    rpc = RpcClient(omp, deviceId: 'test');
    // Before the client reads, so no frame goes by unseen.
    companion = CompanionClient(rpc);
  }

  final FakeOmp omp;
  bool detached = false;

  @override
  final String cwd;

  @override
  final String runId;

  @override
  late final RpcClient rpc;

  @override
  late final CompanionClient companion;

  Future<void> attach() => rpc.attach();

  @override
  SessionView get view => SessionView();

  @override
  Stream<SessionView> get views => const Stream.empty();

  @override
  CompanionHello? get companionHello => CompanionHello.fromJson(const {
    'companion': {'version': '0.1.0'},
    'omp': {'version': '18.3.1'},
    'channel': 'output',
    'verbs': <String>[],
    'events': <String>[],
  });

  @override
  String? get sessionPath => null;

  @override
  LinkState get linkState => const LinkLive();

  @override
  Stream<LinkState> get linkStates => const Stream.empty();

  @override
  void dismissRequest(String id) {}

  @override
  void setPendingPrompt(PendingPrompt? prompt) {}

  @override
  void dismissNotice(int seq) {}

  @override
  void reconnectNow() {}

  @override
  Future<void> detach() async => detached = true;

  @override
  Future<void> stop() async {}
}

/// A machine's files by SFTP path. While [writeGate] is set, writes wait for it.
final class MemoryFiles extends Fake implements HostFiles {
  final texts = <String, String>{};
  Completer<void>? writeGate;

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) async {
    if (texts[path] case final text?) return HostFileStat(size: utf8.encode(text).length, isDirectory: false);
    return texts.keys.any((file) => file.startsWith('$path/')) ? const HostFileStat(size: 0, isDirectory: true) : null;
  }

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) async => utf8.encode(texts[path]!);

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) async {
    await writeGate?.future;
    texts[path] = utf8.decode(bytes);
  }

  @override
  Future<void> mkdir(String path, {int? mode}) async {}

  @override
  Future<void> close() async {}
}

/// A Linux machine without omp (home `/home/u`) whose files are [memory]. Probing it gives [MachineNeedsOmp],
/// which keeps the link usable.
final class FakeLink implements HostLink {
  FakeLink(this.memory);

  final MemoryFiles memory;
  final _done = Completer<void>();

  @override
  String get label => 'fake';

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) async => _ProbeProcess();

  @override
  Future<HostFiles> files() async => memory;

  @override
  Future<HostSocket> connect(String host, int port) => throw UnimplementedError();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }
}

/// Answers the shell probe (no stdin) and the POSIX probe script (`m='<marker>'` first on stdin).
final class _ProbeProcess implements HostProcess {
  final _stdin = BytesBuilder();
  final _stdout = StreamController<Uint8List>();
  final _exit = Completer<HostExit>();

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(List<int> bytes) => _stdin.add(bytes);

  @override
  Future<void> closeStdin() async {
    final marker = RegExp("^m='([^']+)'").firstMatch(utf8.decode(_stdin.takeBytes()))?.group(1);
    final probe = jsonEncode({
      'v': '1',
      'kernel': 'Linux',
      'machine': 'x86_64',
      'home': '/home/u',
      'agentDir': '/home/u/.omp/agent',
      'omps': <Object?>[],
    });
    _stdout.add(utf8.encode(marker == null ? 'OMPANION_SHELL.%OS%..\n' : '\n$marker:begin\n$probe\n$marker:end\n'));
    unawaited(_stdout.close());
    _exit.complete(const HostExit(code: 0));
  }

  @override
  Future<HostExit> get exit => _exit.future;

  @override
  void resize(int columns, int rows) {}

  @override
  void kill() {}

  @override
  Future<void> close() async {}
}

/// A runtime connected to [link] and probed.
Future<MachineRuntime> probedRuntime(HostLink link) async {
  final runtime = MachineRuntime(connect: () async => link, deviceId: 'test', companionBytes: (_) async => const []);
  await runtime.connectAndProbe();
  return runtime;
}

/// What the configuration pages use of [SessionsProvider]: [machine]'s [runtime], its control session from
/// [onControl], and [activeSession] as the chat's session on [machine].
final class FakeSessions extends Fake implements SessionsProvider {
  FakeSessions(this.machine, [this.runtime]);

  final Machine machine;
  final MachineRuntime? runtime;
  Future<LiveSession> Function() onControl = () => throw StateError('no control session');
  LiveSession? activeSession;

  @override
  MachineRuntime runtimeFor(Machine machine) => runtime ?? (throw StateError('no runtime'));

  @override
  Future<LiveSession> control(Machine machine) => onControl();

  @override
  LiveSession? get active => activeSession;

  @override
  Machine? machineOf(LiveSession session) => identical(session, activeSession) ? machine : null;
}

final testMachine = LocalMachine(id: 'm', name: 'test', createdAt: DateTime(2026), updatedAt: DateTime(2026));

/// [child] in an app with translations and a scaffold.
Widget configHost(Widget child) => TranslationProvider(
  child: MaterialApp(home: Scaffold(body: child)),
);
