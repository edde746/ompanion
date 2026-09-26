import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omp_core/channel.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';

import '../omp_binary.dart';

/// A temporary machine for tests on this computer: `home/` is an isolated omp home (testing/omp-home.sh,
/// fake provider on a port nothing listens on, so no model turn can run) with the release binary linked at
/// `~/.local/bin/omp`, and `work dir/` is a project directory whose name needs quoting.
final class TestHost {
  TestHost._(this.root);

  static Future<TestHost> create() async {
    final root = await Directory.systemTemp.createTemp('ompanion-host-');
    final host = TestHost._(root);
    await Directory(host.home).create();
    await Directory(host.work).create();
    final result = await Process.run('sh', ['$repoRoot/testing/omp-home.sh', host.home, '9']);
    if (result.exitCode != 0) throw StateError('omp-home.sh failed: ${result.stderr}');
    await Directory('${host.home}/.local/bin').create(recursive: true);
    await Link('${host.home}/.local/bin/omp').create(ompBinary);
    return host;
  }

  final Directory root;

  String get home => '${root.path}/home';

  String get work => '${root.path}/work dir';

  /// Only system directories on PATH, so the user's own omp is never found; omp's directory overrides are
  /// cleared (an explicitly empty value selects the default).
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

  late final LocalLink link = LocalLink(environment: environment);

  /// Stops every run still alive (force), then deletes everything.
  Future<void> dispose(HostProbe probe) async {
    for (final run in await listRuns(link, probe)) {
      if (run.live) await stopRun(link, probe, run, force: true, timeout: const Duration(seconds: 10));
    }
    await removeDeadRuns(link, probe);
    await link.close();
    await root.delete(recursive: true);
  }
}

/// Collects the JSON frames of a channel and waits for particular ones.
final class Frames {
  Frames(Stream<String> lines) {
    _subscription = lines.listen(
      (line) {
        raw.add(line);
        final Object? value;
        try {
          value = jsonDecode(line);
        } on FormatException {
          return;
        }
        if (value is Map<String, Object?>) {
          frames.add(value);
          _changed();
        }
      },
      onError: (Object error) {
        this.error = error;
        _changed();
      },
      onDone: () {
        done = true;
        _changed();
      },
    );
  }

  late final StreamSubscription<String> _subscription;
  final raw = <String>[];
  final frames = <Map<String, Object?>>[];
  Object? error;
  bool done = false;
  Completer<void> _signal = Completer<void>();

  void _changed() {
    final signal = _signal;
    _signal = Completer<void>();
    signal.complete();
  }

  /// The first frame (from [from] on) matching [test].
  Future<Map<String, Object?>> next(
    bool Function(Map<String, Object?> frame) test, {
    int from = 0,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (var i = from; i < frames.length; i++) {
        if (test(frames[i])) return frames[i];
      }
      if (error != null) throw StateError('channel failed: $error');
      if (done) throw StateError('channel ended; frames: ${frames.map((f) => f['type']).toList()}');
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) throw TimeoutException('no matching frame; got ${frames.map((f) => f['type']).toList()}');
      await _signal.future.timeout(left, onTimeout: () {});
    }
  }

  Future<Map<String, Object?>> response(String id) =>
      next((frame) => frame['type'] == 'response' && frame['id'] == id);

  /// Waits until the lines stream ends.
  Future<void> ended({Duration timeout = const Duration(seconds: 30)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!done) {
      final left = deadline.difference(DateTime.now());
      if (left.isNegative) throw TimeoutException('channel did not end');
      await _signal.future.timeout(left, onTimeout: () {});
    }
  }

  Future<void> cancel() => _subscription.cancel();
}

String getState(String id) => jsonEncode({'id': id, 'type': 'get_state'});
