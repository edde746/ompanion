// Host side of the store-screenshot capture.
//
// The app cannot photograph itself with the system status bar — a Flutter-side screenshot renders only the
// Flutter view — so every shot is taken from the host: `xcrun simctl io <udid> screenshot` on iOS,
// `adb -s <serial> exec-out screencap -p` on Android. The timing comes from a file channel in the app's own
// temporary directory, which is a directory on this Mac for a simulator:
//
//   <app tmp>/ompanion-shots/<name>.request   the test asks for a screenshot and waits
//   <app tmp>/ompanion-shots/<name>.done      this driver wrote <out>/<name>.png
//
// This driver polls that directory while `integration_test` runs (the `onScreenshot` callback of
// `integrationDriver` only fires once the test is over, which is too late to photograph anything).
//
//   OMPANION_SHOT_TARGET=ios:<udid>|android:<serial>   the device
//   OMPANION_SHOT_DIR=<dir>                            where the PNGs land
//   OMPANION_SHOT_ADB=<path>                           the adb binary (default: adb on PATH)
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

const _bundle = 'com.edde746.ompanion';

Future<void> main() async {
  final target = Platform.environment['OMPANION_SHOT_TARGET'] ?? '';
  final kind = target.split(':').first;
  final device = target.substring(target.indexOf(':') + 1);
  if (device.isEmpty || (kind != 'ios' && kind != 'android')) {
    stderr.writeln('set OMPANION_SHOT_TARGET=ios:<udid> or android:<serial> (got "$target")');
    exit(2);
  }
  final out = Directory(Platform.environment['OMPANION_SHOT_DIR'] ?? '/tmp/ompanion-store/shots')
    ..createSync(recursive: true);
  final log = File('${out.path}/driver.log');
  final adb = Platform.environment['OMPANION_SHOT_ADB'] ?? 'adb';

  void note(String message) {
    final line = '${DateTime.now().toIso8601String()} $message\n';
    log.writeAsStringSync(line, mode: FileMode.append, flush: true);
    stdout.write(line);
  }

  if (kind == 'android') await Process.run(adb, ['-s', device, 'logcat', '-c']);
  final shots = _Shots(kind: kind, device: device, adb: adb, out: out, note: note);
  final watching = shots.watch();
  try {
    await integrationDriver(responseDataCallback: (data) async => note(jsonEncode({'reported': data})));
  } finally {
    await shots.stop();
    try {
      await watching;
    } on Object {
      // The poller ends with the run; its own failures are already reported.
    }
  }
  note('captured ${shots.captured} screenshot(s) into ${out.path}');
}

class _Shots {
  _Shots({required this.kind, required this.device, required this.adb, required this.out, required this.note});

  final String kind;
  final String device;
  final String adb;
  final Directory out;
  final void Function(String) note;
  final _pending = <String>{};

  int captured = 0;
  bool _stopped = false;
  String? _deviceDir;

  Future<void> watch() async {
    while (!_stopped) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      if (_stopped) return;
      try {
        for (final name in await _requests()) {
          if (_pending.add(name)) {
            await _capture(name);
            _pending.remove(name);
          }
        }
      } on Object catch (error) {
        note('poll failed: $error');
      }
    }
  }

  Future<void> stop() async {
    _stopped = true;
  }

  /// The app-side directory of the shot channel, resolved once: it only exists after `flutter drive` has
  /// installed the app.
  Future<String?> _dir() async {
    if (_deviceDir != null) return _deviceDir;
    if (kind == 'ios') {
      final result = await Process.run('xcrun', ['simctl', 'get_app_container', device, _bundle, 'data']);
      if (result.exitCode != 0) return null;
      _deviceDir = '${(result.stdout as String).trim()}/tmp/ompanion-shots';
    } else {
      // An app's temp directory is inside its sandbox, so the test announces the path in its stdout and this
      // reads it out of logcat; `run-as` then reaches it, which is how the app's own files are read here.
      final result = await Process.run(adb, ['-s', device, 'logcat', '-d', '-s', 'flutter:I']);
      final announced = RegExp(r'\[shots\] channel (\S+)').firstMatch(result.stdout as String);
      if (announced == null) return null;
      _deviceDir = announced.group(1);
    }
    return _deviceDir;
  }

  Future<List<String>> _requests() async {
    final dir = await _dir();
    if (dir == null) return const [];
    if (kind == 'ios') {
      final folder = Directory(dir);
      if (!folder.existsSync()) return const [];
      return [
        for (final entry in folder.listSync())
          if (entry is File && entry.path.endsWith('.request')) entry.uri.pathSegments.last.replaceAll('.request', ''),
      ];
    }
    final result = await Process.run(adb, ['-s', device, 'shell', 'run-as', _bundle, 'ls', _deviceDir!]);
    if (result.exitCode != 0) return const [];
    return [
      for (final line in (result.stdout as String).split('\n'))
        if (line.trim().endsWith('.request')) line.trim().replaceAll('.request', ''),
    ];
  }

  Future<void> _capture(String name) async {
    final file = File('${out.path}/$name.png');
    final capturedOk = kind == 'ios' ? await _simctl(file) : await _adb(file);
    if (!capturedOk) {
      note('capture of $name failed');
      return;
    }
    await _ack(name);
    captured += 1;
    note('captured $name (${await file.length()} bytes)');
  }

  Future<bool> _simctl(File file) async {
    final result = await Process.run('xcrun', ['simctl', 'io', device, 'screenshot', '--type=png', file.path]);
    if (result.exitCode != 0) {
      note('simctl screenshot failed: ${result.stderr}');
      return false;
    }
    return true;
  }

  Future<bool> _adb(File file) async {
    final result = await Process.run(adb, ['-s', device, 'exec-out', 'screencap', '-p'], stdoutEncoding: null);
    if (result.exitCode != 0) {
      note('adb screencap failed: ${result.stderr}');
      return false;
    }
    await file.writeAsBytes(result.stdout as List<int>, flush: true);
    return true;
  }

  /// Removes the request and writes the ack the test is waiting for.
  Future<void> _ack(String name) async {
    final dir = _deviceDir;
    if (dir == null) return;
    if (kind == 'ios') {
      final request = File('$dir/$name.request');
      if (request.existsSync()) request.deleteSync();
      File('$dir/$name.done').writeAsStringSync('ok');
      return;
    }
    await Process.run(adb, ['-s', device, 'shell', 'run-as', _bundle, 'rm', '-f', '$_deviceDir/$name.request']);
    await Process.run(adb, ['-s', device, 'shell', 'run-as', _bundle, 'touch', '$_deviceDir/$name.done']);
  }
}
