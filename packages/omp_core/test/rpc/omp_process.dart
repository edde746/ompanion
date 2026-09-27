import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:omp_core/transport.dart';

import '../omp_binary.dart';

String shellQuote(String value) => "'${value.replaceAll("'", r"'\''")}'";

/// An isolated omp home (harness/omp-home.sh) plus a working directory outside the repository.
/// Nothing listens on the fake provider's port: these tests never run a model turn.
final class OmpHome {
  OmpHome._(this.root);

  final Directory root;

  String get home => '${root.path}/home';

  String get work => '${root.path}/work';

  static Future<OmpHome> create() async {
    final root = await Directory.systemTemp.createTemp('omp-rpc-');
    final ompHome = OmpHome._(root);
    await Directory(ompHome.work).create();
    final result = await Process.run('sh', ['$repoRoot/harness/omp-home.sh', ompHome.home, '9']);
    if (result.exitCode != 0) throw StateError('omp-home.sh failed: ${result.stderr}');
    return ompHome;
  }

  Future<void> delete() => root.delete(recursive: true);

  /// Starts `omp --mode rpc-ui --no-session --model fake/fake-1 [args]` with only this home's
  /// environment (no provider keys), attached to its stdio.
  Future<OmpProcess> launch([List<String> args = const []]) async {
    final link = LocalLink(environment: {'HOME': home});
    final command = [
      'cd ${shellQuote(work)} &&',
      r'exec env -i HOME="$HOME" PATH="$PATH" TMPDIR="${TMPDIR:-/tmp}" USER="$USER" LANG="${LANG:-C.UTF-8}"',
      shellQuote(ompBinary),
      '--mode rpc-ui --no-session --model fake/fake-1',
      ...args.map(shellQuote),
    ].join(' ');
    return OmpProcess._(link, await link.exec(command));
  }
}

/// A running omp and the attached [LineChannel] over its stdio.
///
/// stdout is read until omp exits even after the client stops listening: omp flushes output while
/// it shuts down, and a closed pipe makes it exit 1.
final class OmpProcess implements LineChannel {
  OmpProcess._(this._link, this.process) {
    _stderr = process.stderr.cast<List<int>>().transform(utf8.decoder).listen(stderr.write);
    _stdout = decodeLines(process.stdout).listen((line) {
      if (line.startsWith('{"type":"rpc_chunk"')) chunkLines++;
      _lines.add(line);
    }, onDone: _lines.close);
  }

  final LocalLink _link;
  final HostProcess process;
  final StreamController<String> _lines = StreamController();
  late final StreamSubscription<String> _stdout;
  late final StreamSubscription<String> _stderr;

  /// omp's stderr, for failure messages.
  final StringBuffer stderr = StringBuffer();

  /// `rpc_chunk` lines seen so far.
  int chunkLines = 0;

  @override
  Stream<String> get lines => _lines.stream;

  @override
  Future<void> send(String line) async => process.write(utf8.encode('$line\n'));

  /// Closing stdin is omp's graceful stop: it drains accepted commands and exits 0.
  @override
  Future<void> close() => process.closeStdin();

  /// Waits for omp to exit after [close]; kills it after [timeout].
  Future<HostExit> exit({Duration timeout = const Duration(seconds: 20)}) async {
    try {
      return await process.exit.timeout(timeout);
    } on TimeoutException {
      process.kill();
      return process.exit;
    } finally {
      await _stdout.cancel();
      await _stderr.cancel();
      unawaited(_lines.close());
      await _link.close();
    }
  }
}
