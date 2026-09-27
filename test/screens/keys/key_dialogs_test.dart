import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';
import 'package:ompanion/screens/keys/key_dialogs.dart';

const _pem = '-----BEGIN OPENSSH PRIVATE KEY-----\nsecret\n-----END OPENSSH PRIVATE KEY-----\n';

void main() {
  late Directory temp;

  setUp(() => temp = Directory.systemTemp.createTempSync('key file '));
  tearDown(() => temp.deleteSync(recursive: true));

  File write(String relative, List<int> bytes) => File('${temp.path}/$relative')
    ..createSync(recursive: true)
    ..writeAsBytesSync(bytes);

  /// Opens the import dialog, chooses [picked] in the picker and waits for the dialog to take it in.
  Future<void> choose(WidgetTester tester, File picked) async {
    FilePickerPlatform.instance = _Picker(picked.path);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      TranslationProvider(
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  TextButton(onPressed: () => showImportKeyDialog(context), child: const Text('open')),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(t.common.chooseFile));
    // File reads complete outside the test's fake clock.
    for (var i = 0; i < 200 && !_tookIn(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(_tookIn(), isTrue);
  }

  testWidgets('a key file picked on Android or iOS leaves no copy of it in the app storage', (tester) async {
    // Another pick's copy, which a pending chat attachment may still need.
    final unrelated = write(
      switch (defaultTargetPlatform) {
        TargetPlatform.android => 'cache/file_picker/1700000000000/notes.pdf',
        _ => 'tmp/0B1C2D3E-4F50-6172-8394-A5B6C7D8E9F0/notes.pdf',
      },
      [1],
    );
    final picked = switch (defaultTargetPlatform) {
      TargetPlatform.android => write('cache/file_picker/1700000000001/id_ed25519', _pem.codeUnits),
      _ => write('tmp/9F8E7D6C-5B4A-3928-1706-F5E4D3C2B1A0/id_ed25519', _pem.codeUnits),
    };
    final inbox = write('tmp/app.ompanion-Inbox/id_ed25519', _pem.codeUnits);

    await choose(tester, picked);

    expect(find.text(_pem), findsOneWidget);
    expect(find.text('id_ed25519'), findsOneWidget);
    expect(picked.parent.existsSync(), isFalse);
    expect(inbox.existsSync(), defaultTargetPlatform != TargetPlatform.iOS);
    expect(unrelated.existsSync(), isTrue);
  }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));

  testWidgets('a picked file the import refuses leaves no copy either', (tester) async {
    final tooLarge = write('cache/file_picker/1700000000002/big', Uint8List(64 * 1024 + 1));
    await choose(tester, tooLarge);
    expect(find.text(t.keys.fileTooLarge), findsOneWidget);
    expect(tooLarge.parent.existsSync(), isFalse);

    final binary = write('cache/file_picker/1700000000003/photo.jpg', [0xff, 0xd8, 0xff]);
    await choose(tester, binary);
    expect(find.text(t.keys.malformed), findsOneWidget);
    expect(binary.parent.existsSync(), isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets("on desktop the picked key file is the user's own and stays", (tester) async {
    final picked = write('home/.ssh/id_ed25519', _pem.codeUnits);
    await choose(tester, picked);
    expect(find.text(_pem), findsOneWidget);
    expect(picked.existsSync(), isTrue);
  }, variant: const TargetPlatformVariant({TargetPlatform.macOS, TargetPlatform.linux, TargetPlatform.windows}));
}

/// The dialog shows the picked key or why it refused the file.
bool _tookIn() => [
  find.text(_pem),
  find.text(t.keys.fileTooLarge),
  find.text(t.keys.malformed),
].any((finder) => finder.evaluate().isNotEmpty);

/// A picker whose pick is the file at [path], as the platform's picker hands it over.
final class _Picker extends FilePickerPlatform {
  _Picker(this.path);

  final String path;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _Picked(File(path));
}

final class _Picked extends PlatformFile {
  _Picked(this.file);

  final File file;

  @override
  String get name => file.uri.pathSegments.last;

  @override
  Uri get uri => file.uri;

  @override
  Never get xFile => throw UnimplementedError();

  @override
  int? lengthSync() => null;

  @override
  Future<int?> length() => file.length();

  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();

  @override
  Stream<Uint8List> readAsByteStream() => file.openRead().map(Uint8List.fromList);
}
