import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/store.dart';
import 'package:omp_core/transport.dart';

import '../omp_binary.dart';

/// The companion build the app ships (`cd companion && bun run build`).
Future<List<int>> companionBytes(String ompVersion) async {
  final file = File('$repoRoot/companion/dist/ompx.js');
  if (!file.existsSync()) throw StateError('${file.path} is missing; run `bun run build` in companion/');
  return file.readAsBytes();
}

/// `testing/fake-provider/server.ts` on a free port of [host]: scripted turns only, never a paid model.
final class FakeProvider {
  FakeProvider._(this._process, this.host, this.port);

  static Future<FakeProvider> start({String host = '127.0.0.1'}) async {
    final process = await Process.start('bun', [
      '$repoRoot/testing/fake-provider/server.ts',
      '--host',
      host,
      '--port',
      '0',
    ]);
    final listening = Completer<int>();
    process.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      final port = RegExp(r'^listening (\d+)$').firstMatch(line)?.group(1);
      if (port != null && !listening.isCompleted) listening.complete(int.parse(port));
    });
    final errors = StringBuffer();
    process.stderr.transform(utf8.decoder).listen(errors.write);
    unawaited(
      process.exitCode.then((code) {
        if (!listening.isCompleted) listening.completeError(StateError('fake provider exited $code: $errors'));
      }),
    );
    return FakeProvider._(process, host, await listening.future.timeout(const Duration(seconds: 30)));
  }

  final Process _process;
  final String host;
  final int port;

  /// Appends turns; each answers one model request, in order (testing/README.md).
  Future<void> enqueue(List<Map<String, Object?>> turns) => _call('POST', '/control/enqueue', turns);

  /// Clears the queue and the request log.
  Future<void> reset() => _call('POST', '/control/reset');

  /// Every model request so far.
  Future<List<Object?>> requests() async => (await _call('GET', '/control/requests')) as List<Object?>;

  Future<Object?> _call(String method, String path, [Object? body]) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(method, Uri.parse('http://$host:$port$path'));
      if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close();
      final text = await response.transform(utf8.decoder).join();
      if (response.statusCode != 200) throw StateError('$method $path: ${response.statusCode} $text');
      return text.isEmpty ? null : jsonDecode(text);
    } finally {
      client.close();
    }
  }

  Future<void> stop() async {
    _process.kill();
    await _process.exitCode;
  }
}

/// An HTTP proxy that forwards nothing: it records the first line of every request (`CONNECT host:443 …` for HTTPS)
/// and closes the connection. omp (Bun's fetch) honours the proxy variables, so a machine with [environment] cannot
/// reach any host outside this computer's loopback.
final class ProxyRecorder {
  ProxyRecorder._(this._server) {
    _server.listen((socket) {
      socket
          .cast<List<int>>()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first
          .then(requests.add, onError: (Object error) => requests.add('unreadable request: $error'))
          .whenComplete(socket.destroy);
    });
  }

  static Future<ProxyRecorder> start() async => ProxyRecorder._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _server;
  final requests = <String>[];

  Map<String, String> get environment => {
    for (final name in ['HTTP_PROXY', 'HTTPS_PROXY', 'http_proxy', 'https_proxy']) name: 'http://127.0.0.1:${_server.port}',
    for (final name in ['NO_PROXY', 'no_proxy']) name: '127.0.0.1,localhost',
  };

  Future<void> close() => _server.close();
}

/// A machine on this computer: an isolated omp home from `testing/dev-machine.sh` (the fake provider, the pinned omp
/// at `~/.local/bin/omp`, `modelRoles.default: fake/fake-1`, `~/demo-project`).
final class DevMachine {
  DevMachine._(this.root);

  static Future<DevMachine> create(int port) async {
    final root = await Directory.systemTemp.createTemp('ompanion-session-');
    final machine = DevMachine._(root);
    final result = await Process.run('sh', ['$repoRoot/testing/dev-machine.sh', machine.home, '$port']);
    if (result.exitCode != 0) throw StateError('dev-machine.sh failed: ${result.stderr}');
    return machine;
  }

  final Directory root;

  String get home => '${root.path}/home';

  String get project => '$home/demo-project';

  /// Only system directories on PATH, so the user's own omp is never found; omp's directory variables are
  /// cleared (an empty value selects the default).
  Map<String, String> get environment => {
    'HOME': home,
    'PATH': '/usr/bin:/bin:/usr/sbin:/sbin',
    'PI_CODING_AGENT_DIR': '',
    'OMP_PROFILE': '',
    'PI_PROFILE': '',
    'PI_CONFIG_DIR': '',
    'XDG_DATA_HOME': '',
    'XDG_STATE_HOME': '',
    'XDG_CACHE_HOME': '',
  };

  /// [extraEnvironment] adds variables to every process on the machine, e.g. [ProxyRecorder.environment].
  MachineRuntime runtime(
    String deviceId, {
    Map<String, String> overlay = const {},
    Map<String, String> extraEnvironment = const {},
  }) => MachineRuntime(
    connect: () async => LocalLink(environment: {...environment, ...extraEnvironment}),
    deviceId: deviceId,
    companionBytes: companionBytes,
    overlay: overlay,
  );

  /// Stops every run still alive, then deletes the machine.
  Future<void> dispose() async {
    final link = LocalLink(environment: environment);
    final probe = await probeHost(link);
    for (final run in await listRuns(link, probe)) {
      if (run.live) await stopRun(link, probe, run, force: true, timeout: const Duration(seconds: 10));
    }
    await link.close();
    await root.delete(recursive: true);
  }
}

/// The first view of [session] (the current one included) that satisfies [test].
Future<SessionView> viewWhere(
  LiveSession session,
  bool Function(SessionView view) test, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  if (test(session.view)) return session.view;
  return session.views.firstWhere(test).timeout(timeout);
}

/// The first link state of [session] (the current one included) that satisfies [test].
Future<LinkState> linkWhere(
  LiveSession session,
  bool Function(LinkState state) test, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  if (test(session.linkState)) return session.linkState;
  return session.linkStates.firstWhere(test).timeout(timeout);
}

/// The assistant texts of [view], in order.
List<String> answers(SessionView view) => [
  for (final item in view.transcript)
    if (item is AssistantItem && item.text.isNotEmpty) item.text,
];

/// The user texts of [view], in order.
List<String> prompts(SessionView view) => [
  for (final item in view.transcript)
    if (item is UserItem) item.text,
];

bool idle(SessionView view) => !view.run.running;
