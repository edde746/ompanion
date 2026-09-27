import 'dart:convert';
import 'dart:io';

import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';
import 'package:test/test.dart';

PushRegistration _registration({String fid = 'fid-1', Set<NotificationKind> kinds = const {}}) => PushRegistration(
  deviceId: '00112233445566778899aabbccddeeff',
  machineId: 'm1',
  machineName: 'devbox',
  platform: PushPlatform.ios,
  fid: fid,
  key: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
  kinds: kinds,
);

void main() {
  test('a registration encodes to exactly the contract fields, kinds in a fixed order', () {
    final registration = _registration(kinds: {NotificationKind.failed, NotificationKind.input});

    expect(
      utf8.decode(registration.encode()),
      '{"v":1,"deviceId":"00112233445566778899aabbccddeeff","machineId":"m1","machineName":"devbox",'
      '"platform":"ios","fid":"fid-1","key":"AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=",'
      '"kinds":["input","failed"],"relay":"https://push.ompanion.app/v1/send"}\n',
    );
  });

  test('a device id that is not 32 lowercase hex never names a file', () {
    expect(
      () => PushRegistration(
        deviceId: '../x',
        machineId: 'm1',
        machineName: 'devbox',
        platform: PushPlatform.android,
        fid: 'f',
        key: 'k',
        kinds: const {},
      ),
      throwsArgumentError,
    );
  });

  group('on a machine', () {
    late Directory temp;
    late LocalLink link;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('push-');
      link = LocalLink(environment: {'HOME': temp.path});
    });

    tearDown(() async {
      await link.close();
      await temp.delete(recursive: true);
    });

    test('the file is private, kept while unchanged, replaced when changed and removed once', () async {
      final path = '${temp.path}/.ompanion/push/00112233445566778899aabbccddeeff.json';
      await writePushRegistration(link, _registration(kinds: {NotificationKind.done}));
      expect(File(path).readAsBytesSync(), _registration(kinds: {NotificationKind.done}).encode());
      expect(File(path).statSync().mode & 0x1FF, 0x180);
      expect(Directory(File(path).parent.path).statSync().mode & 0x1FF, 0x1C0);

      await Process.run('touch', ['-t', '202001010000', path]);
      await writePushRegistration(link, _registration(kinds: {NotificationKind.done}));
      expect(File(path).statSync().modified.year, 2020, reason: 'the same bytes are not written again');

      await writePushRegistration(link, _registration(fid: 'rotated', kinds: {NotificationKind.done}));
      expect(jsonDecode(File(path).readAsStringSync()), containsPair('fid', 'rotated'));
      expect(Directory(File(path).parent.path).listSync(), hasLength(1), reason: 'no temporary file is left behind');

      // What a link lost between the write and the rename leaves, beside another phone's files.
      final dir = File(path).parent.path;
      File('$dir/00112233445566778899aabbccddeeff.OMPANION_0011223344556677.part').writeAsStringSync('key');
      File('$dir/ffeeddccbbaa99887766554433221100.json').writeAsStringSync('{}');
      File('$dir/ffeeddccbbaa99887766554433221100.OMPANION_0011223344556677.part').writeAsStringSync('key');
      await removePushRegistration(link, '00112233445566778899aabbccddeeff');
      expect(Directory(dir).listSync().map((entry) => entry.uri.pathSegments.last).toSet(), {
        'ffeeddccbbaa99887766554433221100.json',
        'ffeeddccbbaa99887766554433221100.OMPANION_0011223344556677.part',
      }, reason: "this phone's registration and leftovers go, another phone's stay");
      await removePushRegistration(link, '00112233445566778899aabbccddeeff');
    });
  });
}
