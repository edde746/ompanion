import 'dart:async';
import 'dart:typed_data';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:ompanion/sessions/machine_images.dart';

const fakeProbe = HostProbe(
  commandShell: CommandShell.posix,
  os: HostOs.linux,
  kernel: 'Linux',
  arch: 'x64',
  home: '/home/u',
  agentDir: '/home/u/.omp/agent',
);

/// A machine whose image files are [files] (SFTP path → size and modification time). A fetch answers from
/// [answers] when it has the path (the auto load; [originals] for `original: true`), else with [bytesPerImage] bytes
/// whose first byte is the file's size, so images are told apart by content.
final class FakeImageHost implements ImageHost {
  FakeImageHost({this.bytesPerImage = 100, this.id = 'machine-1'});

  final int bytesPerImage;
  final files = <String, ({int size, DateTime modified})>{};
  final answers = <String, HostImage>{};
  final originals = <String, HostImage>{};
  final stats = <String>[];
  final fetches = <(String, bool)>[];
  Completer<void>? gate;

  @override
  final String id;

  @override
  HostProbe? get probe => fakeProbe;

  @override
  Future<HostProbe> connect() async => fakeProbe;

  @override
  Future<HostFileStat?> stat(String path) async {
    stats.add(path);
    final file = files[path];
    return file == null ? null : HostFileStat(size: file.size, isDirectory: false, modified: file.modified);
  }

  @override
  Future<HostImage> fetch(String path, {required bool original}) async {
    fetches.add((path, original));
    await gate?.future;
    final answer = (original ? originals : answers)[path];
    if (answer != null) return answer;
    final file = files[path]!;
    return HostImageBytes(
      bytes: Uint8List(original ? bytesPerImage * 2 : bytesPerImage)..fillRange(0, 1, file.size % 256),
      mimeType: 'image/webp',
      size: file.size,
      modified: file.modified,
      preview: !original,
    );
  }
}
