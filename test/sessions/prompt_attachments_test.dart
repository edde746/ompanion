import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:omp_core/companion.dart';
import 'package:omp_core/rpc.dart';
import 'package:omp_core/session.dart';
import 'package:omp_core/transport.dart';
import 'package:ompanion/sessions/composer_attachments.dart';
import 'package:ompanion/sessions/prompt_attachments.dart';

/// A session whose process has no companion: anything that needs the machine's `local://` directory fails.
final class _Session implements LiveSession {
  @override
  Future<void> Function()? get loadEarlier => null;
  @override
  CompanionHello? get companionHello => null;

  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Another machine, as far as [preparePrompt] can tell.
final class _Elsewhere implements HostLink {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _image = RpcImage(data: 'iVBORw0KGgo=', mimeType: 'image/png');

void main() {
  late Directory temp;
  late int links;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('prompt-attachments-');
    links = 0;
  });

  tearDown(() => temp.delete(recursive: true));

  Future<PreparedPrompt> prepare(String text, List<ComposerAttachment> attachments, {HostLink? link}) => preparePrompt(
    text: text,
    attachments: attachments,
    session: _Session(),
    link: () async {
      links++;
      return link ?? LocalLink();
    },
  );

  group('assembleMessage', () {
    test('appends each part after the typed text as the TUI expands a chip typed at the end', () {
      expect(assembleMessage('explain', ['one\ntwo', '@"/a b.txt"']), 'explain one\ntwo @"/a b.txt"');
      expect(assembleMessage('explain:\n', ['body']), 'explain:\nbody');
      expect(assembleMessage('', ['  body\n', 'x']), 'body\n x');
      expect(assembleMessage('  just text  ', []), 'just text');
    });
  });

  group('fileMention', () {
    test('quotes the path in the form file-mentions.ts reads back whole', () {
      expect(fileMention('/home/me/a b@2x.png'), '@"/home/me/a b@2x.png"');
      expect(fileMention(r'C:\Users\me\say "hi".txt'), r"""@'C:\Users\me\say "hi".txt'""");
      expect(fileMention('/tmp/it\'s "both"'), isNull);
      expect(fileMention('/tmp/trailing '), isNull);
    });
  });

  group('preparePrompt', () {
    test('keeps images as image content and small pastes in the message, without touching the machine', () async {
      final prepared = await prepare('look', [const ImageAttachment(_image), const TextAttachment('a\nb')]);
      expect(prepared.message, 'look a\nb');
      expect(prepared.images, [_image]);
      expect(links, 0);
    });

    test('mentions files and folders of this computer where they are, in attachment order', () async {
      final file = File('${temp.path}/build log.txt')..writeAsStringSync('log');
      final folder = Directory('${temp.path}/src')..createSync();
      final prepared = await prepare('why', [
        FileAttachment.path(name: 'build log.txt', size: 3, path: file.path),
        const TextAttachment('pasted'),
        const ImageAttachment(_image),
        FileAttachment.path(name: 'src', size: 0, path: folder.path),
      ]);
      expect(prepared.message, 'why @"${file.path}" pasted @"${folder.path}"');
      expect(prepared.images, [_image]);
    });

    test('a file that left this device fails before anything is sent', () async {
      await expectLater(
        prepare('x', [FileAttachment.path(name: 'gone.txt', size: 1, path: '${temp.path}/gone.txt')]),
        throwsA(isA<AttachmentMissing>().having((error) => error.name, 'name', 'gone.txt')),
      );
      expect(links, 0);
    });

    test('a file above the limit is refused by its size on disk now', () async {
      final big = File('${temp.path}/big.bin');
      (big.openSync(mode: FileMode.write)..truncateSync(maxAttachmentBytes + 1)).closeSync();
      await expectLater(
        prepare('x', [FileAttachment.path(name: 'big.bin', size: 1, path: big.path)]),
        throwsA(isA<AttachmentTooLarge>().having((error) => error.size, 'size', maxAttachmentBytes + 1)),
      );
    });

    test('a folder cannot go to another machine', () async {
      await expectLater(
        prepare('x', [FileAttachment.path(name: 'src', size: 0, path: temp.path)], link: _Elsewhere()),
        throwsA(isA<AttachmentIsFolder>()),
      );
    });

    test('an upload or a large paste without the companion fails, naming what needed it', () async {
      await expectLater(
        prepare('x', [FileAttachment.bytes(name: 'shot.bin', bytes: Uint8List(4))]),
        throwsA(isA<AttachmentNeedsCompanion>().having((error) => error.name, 'name', 'shot.bin')),
      );
      await expectLater(
        prepare('x', [TextAttachment('x' * (pasteFileThreshold + 1))], link: _Elsewhere()),
        throwsA(isA<AttachmentNeedsCompanion>().having((error) => error.name, 'name', isNull)),
      );
    });
  });
}
