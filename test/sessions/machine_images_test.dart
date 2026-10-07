import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_core/host.dart';
import 'package:ompanion/sessions/machine_images.dart';

import 'fake_image_host.dart';

void main() {
  late Directory temp;
  late DateTime now;
  late FakeImageHost machine;

  MachineImages images({int memoryBytes = 48 << 20, int diskBytes = 256 << 20}) =>
      MachineImages(cacheDir: () async => temp, memoryBytes: memoryBytes, diskBytes: diskBytes, clock: () => now);

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('machine images ');
    now = DateTime.utc(2026, 9, 26, 10);
    machine = FakeImageHost();
    machine.files['/home/u/a.png'] = (size: 1000, modified: DateTime.utc(2026, 9, 1));
  });

  tearDown(() => temp.delete(recursive: true));

  test('a second load, a rebuild and a reopened app do not fetch the image again', () async {
    final first = images();
    final image = await first.load(machine, '/home/u/a.png') as HostImageBytes;
    expect(machine.fetches, [('/home/u/a.png', false)]);

    expect(identical(await first.load(machine, '/home/u/a.png'), image), isTrue);
    expect(identical(first.peek(machine, '/home/u/a.png'), image), isTrue);
    expect(machine.stats, hasLength(1), reason: 'within the freshness window no stat either');

    final reopened = images();
    expect(reopened.peek(machine, '/home/u/a.png'), isNull);
    final fromDisk = await reopened.load(machine, '/home/u/a.png') as HostImageBytes;
    expect(fromDisk.bytes, image.bytes);
    expect((fromDisk.size, fromDisk.modified, fromDisk.preview), (1000, image.modified, true));
    expect(machine.fetches, hasLength(1));
  });

  test('after the freshness window a stat decides: the same file stays, a changed one is fetched again', () async {
    final cache = images();
    await cache.load(machine, '/home/u/a.png');
    now = now.add(const Duration(minutes: 1));
    await cache.load(machine, '/home/u/a.png');
    expect((machine.stats.length, machine.fetches.length), (2, 1));

    machine.files['/home/u/a.png'] = (size: 1001, modified: DateTime.utc(2026, 9, 2));
    now = now.add(const Duration(minutes: 1));
    final changed = await cache.load(machine, '/home/u/a.png') as HostImageBytes;
    expect(changed.size, 1001);
    expect(machine.fetches, hasLength(2));
  });

  test('loads of one image at the same time share one fetch', () async {
    final cache = images();
    machine.gate = Completer();
    final loads = [cache.load(machine, '/home/u/a.png'), cache.load(machine, '/home/u/a.png')];
    await pumpEventQueue();
    machine.gate!.complete();
    final [a, b] = await Future.wait(loads);
    expect(identical(a, b), isTrue);
    expect(machine.fetches, hasLength(1));
  });

  test('two fetches of a machine run at once; a waiting one runs only while a load still wants it', () async {
    for (final name in ['b', 'c', 'd']) {
      machine.files['/home/u/$name.png'] = (size: 1000, modified: DateTime.utc(2026));
    }
    final cache = images();
    machine.gate = Completer();
    Future<void> until(bool Function() done, String what) async {
      for (var waited = 0; !done(); waited++) {
        if (waited == 2000) fail('$what did not happen within 2 s');
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
    }

    final running = [cache.load(machine, '/home/u/a.png'), cache.load(machine, '/home/u/b.png')];
    await until(() => machine.fetches.length == 2, 'fetching a and b');
    // A load is asked whether it still wants its image once it reached the fetch.
    final asked = <String>{};
    var cShown = true;
    bool Function() shown(String name, bool Function() answer) => () {
      asked.add(name);
      return answer();
    };
    final c = cache.load(machine, '/home/u/c.png', wanted: shown('c', () => cShown));
    final d = [
      cache.load(machine, '/home/u/d.png', wanted: () => false),
      cache.load(machine, '/home/u/d.png', wanted: shown('d', () => true)),
    ];
    await until(() => asked.containsAll(['c', 'd']), 'c and d reaching the fetch');
    expect(machine.fetches, hasLength(2), reason: 'c and d wait for a turn');

    cShown = false;
    final abandoned = expectLater(c, throwsA(isA<ImageLoadAbandoned>()));
    machine.gate!.complete();
    await Future.wait([...running, ...d]);
    await abandoned;
    expect(
      machine.fetches.map((fetch) => fetch.$1),
      unorderedEquals(['/home/u/a.png', '/home/u/b.png', '/home/u/d.png']),
      reason: 'c scrolled away before its turn; one of d\'s two loads still showed it',
    );
  });

  test('the original, once loaded, stands in for the preview', () async {
    final cache = images();
    final original = await cache.load(machine, '/home/u/a.png', original: true) as HostImageBytes;
    expect(original.preview, isFalse);
    expect(identical(cache.peek(machine, '/home/u/a.png'), original), isTrue);
    expect(identical(await cache.load(machine, '/home/u/a.png'), original), isTrue);
    expect(machine.fetches, [('/home/u/a.png', true)]);
  });

  test('a missing file and a file over 64 MB are known from the stat, without running anything', () async {
    final cache = images();
    machine.files['/home/u/huge.png'] = (size: (64 << 20) + 1, modified: DateTime.utc(2026));
    final missing = await cache.load(machine, '/home/u/gone.png') as HostImageProblem;
    final huge = await cache.load(machine, '/home/u/huge.png') as HostImageProblem;
    expect(
      (missing.issue, huge.issue, huge.size, huge.canLoadOriginal),
      (HostImageIssue.missing, HostImageIssue.tooLarge, (64 << 20) + 1, false),
    );
    expect(machine.fetches, isEmpty);
  });

  test('memory keeps the most recently used images within its bound', () async {
    for (final name in ['b', 'c', 'd']) {
      machine.files['/home/u/$name.png'] = (size: 1000, modified: DateTime.utc(2026));
    }
    final cache = images(memoryBytes: 250);
    await cache.load(machine, '/home/u/a.png');
    await cache.load(machine, '/home/u/b.png');
    await cache.load(machine, '/home/u/a.png');
    await cache.load(machine, '/home/u/c.png');
    expect(cache.peek(machine, '/home/u/b.png'), isNull, reason: 'b was used least recently');
    expect(cache.peek(machine, '/home/u/a.png'), isNotNull);
    expect(cache.peek(machine, '/home/u/c.png'), isNotNull);
  });

  test('the disk keeps the most recently used images within its bound', () async {
    for (final name in ['b', 'c']) {
      machine.files['/home/u/$name.png'] = (size: 1000, modified: DateTime.utc(2026));
    }
    // Each file holds a header of about 200 bytes and 100 image bytes: two fit, three do not.
    final writer = images(diskBytes: 700);
    for (final name in ['a', 'b']) {
      await writer.load(machine, '/home/u/$name.png');
      now = now.add(const Duration(seconds: 1));
    }
    await images().load(machine, '/home/u/a.png');
    now = now.add(const Duration(seconds: 1));
    await writer.load(machine, '/home/u/c.png');
    expect(machine.fetches, hasLength(3));

    final reopened = images();
    for (final name in ['a', 'c', 'b']) {
      await reopened.load(machine, '/home/u/$name.png');
    }
    expect(machine.fetches.skip(3), [('/home/u/b.png', false)], reason: 'b, not a, was evicted: reading a used it');
  });
}
