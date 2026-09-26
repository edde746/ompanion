import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/files/file_document.dart';
import 'package:ompanion/files/file_workspace.dart';
import 'package:ompanion/files/git_status.dart';
import 'package:ompanion/screens/dock/agents/agent_transcript.dart';
import 'package:omp_core/host.dart';
import 'package:omp_core/transport.dart';

/// Rows as `ls -F` names: `dir/`, `link@`, `file`.
List<(int, String)> names(List<BrowserRow> rows) => [
  for (final row in rows)
    switch (row) {
      EntryRow(:final depth, :final entry) => (
        depth,
        entry.stat.isLink ? '${entry.name}@' : (entry.stat.isDirectory ? '${entry.name}/' : entry.name),
      ),
      EmptyRow(:final depth) => (depth, '(empty)'),
      LoadingRow(:final depth) => (depth, '(loading)'),
      FailedRow(:final depth) => (depth, '(failed)'),
    },
];

void main() {
  late Directory temp;
  late String root;
  late LocalLink link;
  late HostProbe probe;
  late FileWorkspace workspace;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('dock-files-');
    root = temp.path;
    File('$root/README.md').writeAsStringSync('# Demo\nline two\n');
    File('$root/src/main.dart').createSync(recursive: true);
    File('$root/src/main.dart').writeAsStringSync('void main() {}\n');
    File('$root/src/lib/a.dart').createSync(recursive: true);
    Directory('$root/docs').createSync();
    link = LocalLink(environment: {'HOME': root});
    probe = HostProbe(
      commandShell: CommandShell.posix,
      os: HostOs.macos,
      kernel: 'Darwin',
      arch: 'arm64',
      home: root,
      agentDir: '$root/.omp/agent',
    );
    workspace = FileWorkspace()..connect = () async => (link, probe);
  });

  Future<void> git(List<String> args) async {
    final result = await Process.run('git', [
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      '-c',
      'commit.gpgsign=false',
      ...args,
    ], workingDirectory: root);
    expect(result.exitCode, 0, reason: '${result.stderr}');
  }

  tearDown(() async {
    workspace.dispose();
    await temp.delete(recursive: true);
  });

  test('browses the session directory lazily, folders first; expanded folders nest', () async {
    await workspace.follow(root);
    expect(workspace.root, root);
    expect(names(workspace.rows()), [(0, 'docs/'), (0, 'src/'), (0, 'README.md')]);

    await workspace.toggle('$root/src');
    await workspace.toggle('$root/docs');
    expect(names(workspace.rows()), [
      (0, 'docs/'),
      (1, '(empty)'),
      (0, 'src/'),
      (1, 'lib/'),
      (1, 'main.dart'),
      (0, 'README.md'),
    ]);

    await workspace.toggle('$root/src');
    expect(names(workspace.rows()), [(0, 'docs/'), (1, '(empty)'), (0, 'src/'), (0, 'README.md')]);

    // The same session directory again keeps where the user navigated to.
    await workspace.openDir('$root/src');
    await workspace.follow(root);
    expect(workspace.root, '$root/src');
  });

  test('paths from the transcript resolve against the session directory and home', () async {
    await workspace.follow(root);
    expect(workspace.resolve('src/main.dart', cwd: root), '$root/src/main.dart');
    expect(workspace.resolve('~/README.md', cwd: '/elsewhere'), '$root/README.md');
    expect(workspace.resolve('/etc/hosts', cwd: root), '/etc/hosts');
    expect(workspace.resolve(r'C:\x\y.txt', cwd: root), '/C:/x/y.txt');
  });

  test('edit and save round trip; a change made elsewhere since loading is a conflict', () async {
    await workspace.follow(root);
    await workspace.open('$root/README.md', line: 2);
    final document = workspace.current!;
    expect(document.pendingLine, 2);
    expect(document.controller.text, '# Demo\nline two\n');
    expect(document.dirty, isFalse);

    document.controller.text = '# Demo\nedited\n';
    expect(document.dirty, isTrue);
    await workspace.save(document);
    expect(File('$root/README.md').readAsStringSync(), '# Demo\nedited\n');
    expect(document.dirty, isFalse);

    File('$root/README.md').writeAsStringSync('changed on the machine, and longer\n');
    document.controller.text = 'mine\n';
    await expectLater(workspace.save(document), throwsA(isA<FileChangedOnDisk>()));
    expect(File('$root/README.md').readAsStringSync(), 'changed on the machine, and longer\n');

    await workspace.save(document, force: true);
    expect(File('$root/README.md').readAsStringSync(), 'mine\n');

    File('$root/README.md').deleteSync();
    await expectLater(
      workspace.save(document..controller.text = 'again\n'),
      throwsA(isA<FileChangedOnDisk>().having((conflict) => conflict.deleted, 'deleted', isTrue)),
    );
  });

  test('reopening an open file reuses its document; CRLF files keep their line breaks', () async {
    File('$root/windows.txt').writeAsStringSync('one\r\ntwo\r\n');
    await workspace.follow(root);
    await workspace.open('$root/windows.txt');
    final document = workspace.current!;
    workspace.showBrowser();
    await workspace.open('$root/windows.txt', line: 1);
    expect(identical(workspace.current, document), isTrue);
    expect(workspace.documents, hasLength(1));

    document.controller.text = 'one\ntwo\nthree\n';
    await workspace.save(document);
    expect(File('$root/windows.txt').readAsStringSync(), 'one\r\ntwo\r\nthree\r\n');
  });

  test('saving keeps the line break most lines use; a reload takes the one the file has now', () async {
    File('$root/mixed.txt').writeAsStringSync('one\ntwo\r\nthree\nfour\n');
    await workspace.follow(root);
    await workspace.open('$root/mixed.txt');
    final mixed = workspace.current!;
    mixed.controller.text = 'one\ntwo\nthree\nfour\nfive\n';
    await workspace.save(mixed);
    expect(File('$root/mixed.txt').readAsStringSync(), 'one\ntwo\nthree\nfour\nfive\n');

    File('$root/converted.txt').writeAsStringSync('one\ntwo\n');
    await workspace.open('$root/converted.txt');
    final converted = workspace.current!;
    File('$root/converted.txt').writeAsStringSync('one\r\ntwo\r\n');
    await workspace.reload(converted);
    converted.controller.text = 'one\ntwo\nthree\n';
    await workspace.save(converted);
    expect(File('$root/converted.txt').readAsStringSync(), 'one\r\ntwo\r\nthree\r\n');
  });

  test('a file that reports size 0 (a device, /proc) is read only up to the editable limit', () async {
    final files = _EndlessFiles();
    final document = await FileDocument.load(files, '/dev/zero');
    addTearDown(document.dispose);
    expect(files.lengths, [maxEditableBytes + 1]);
    expect(document.readOnlyReason, ReadOnlyReason.tooLarge);
    expect(document.controller.text.length, maxEditableBytes);
  });

  test('opening a file twice at once, as a double click does, opens one document', () async {
    await workspace.follow(root);
    await Future.wait([workspace.open('$root/README.md'), workspace.open('$root/README.md')]);
    expect(workspace.documents, hasLength(1));
  });

  test('large, binary and non-UTF-8 files open read-only', () async {
    File('$root/big.log').writeAsBytesSync(List.filled(maxEditableBytes + 10, 0x61));
    File('$root/image.png').writeAsBytesSync([0x89, 0x50, 0x4e, 0x47, 0, 0, 0]);
    File('$root/latin1.txt').writeAsBytesSync([0x63, 0x61, 0x66, 0xe9]);
    await workspace.follow(root);
    for (final (name, reason) in [
      ('big.log', ReadOnlyReason.tooLarge),
      ('image.png', ReadOnlyReason.binary),
      ('latin1.txt', ReadOnlyReason.notUtf8),
    ]) {
      await workspace.open('$root/$name');
      expect(workspace.current!.readOnlyReason, reason, reason: name);
    }
    expect(workspace.documents.first.controller.text.length, maxEditableBytes);
    await expectLater(workspace.save(workspace.current!), throwsStateError);
  });

  test('create, rename and delete; open documents follow a rename and close with a delete', () async {
    await workspace.follow(root);
    await workspace.createFile(root, 'notes.txt');
    expect(File('$root/notes.txt').existsSync(), isTrue);
    expect(workspace.current!.path, '$root/notes.txt');
    await expectLater(workspace.createFile(root, 'notes.txt'), throwsA(isA<HostFileExists>()));

    await workspace.createFolder('$root/docs', 'guides');
    expect(Directory('$root/docs/guides').existsSync(), isTrue);

    await workspace.open('$root/src/lib/a.dart');
    final document = workspace.current!;
    await workspace.rename('$root/src', 'source');
    expect(document.path, '$root/source/lib/a.dart');
    expect(Directory('$root/source/lib').existsSync(), isTrue);
    await expectLater(workspace.rename('$root/source', 'docs'), throwsA(isA<HostFileExists>()));

    await workspace.delete('$root/source');
    expect(Directory('$root/source').existsSync(), isFalse);
    expect(workspace.documents.map((document) => document.path), ['$root/notes.txt']);
    expect(names(workspace.rows()).map((entry) => entry.$2), ['docs/', 'notes.txt', 'README.md']);
  });

  test('renaming an expanded folder keeps it and its expanded subfolders listed', () async {
    await workspace.follow(root);
    await workspace.toggle('$root/src');
    await workspace.toggle('$root/src/lib');
    await workspace.rename('$root/src', 'source');
    expect(names(workspace.rows()), [
      (0, 'docs/'),
      (0, 'source/'),
      (1, 'lib/'),
      (2, 'a.dart'),
      (1, 'main.dart'),
      (0, 'README.md'),
    ]);
  });

  test('a rename that changes only the case goes through; another file of that name is never replaced', () async {
    File('$root/notes.txt').writeAsStringSync('mine\n');
    // macOS and Windows file systems ignore case by default; Linux ones do not.
    final ignoresCase = File('$root/NOTES.txt').existsSync();
    await workspace.follow(root);
    if (ignoresCase) {
      await workspace.rename('$root/notes.txt', 'NOTES.txt');
      expect(Directory(root).listSync().map((entity) => entity.uri.pathSegments.last), contains('NOTES.txt'));
      expect(names(workspace.rows()).map((row) => row.$2), contains('NOTES.txt'));
    } else {
      File('$root/NOTES.txt').writeAsStringSync('other\n');
      await expectLater(workspace.rename('$root/notes.txt', 'NOTES.txt'), throwsA(isA<HostFileExists>()));
      expect(File('$root/NOTES.txt').readAsStringSync(), 'other\n');
    }
  });

  test('a symbolic link is listed as a link and deleted as one, never what it points to', () async {
    final outside = await Directory.systemTemp.createTemp('dock-files-outside-');
    addTearDown(() => outside.delete(recursive: true));
    File('${outside.path}/keep.txt').writeAsStringSync('keep\n');
    Link('$root/shared').createSync(outside.path);
    Link('$root/src/inner').createSync(outside.path);
    Link('$root/gone').createSync('$root/missing');

    await workspace.follow(root);
    await workspace.toggle('$root/src');
    expect(names(workspace.rows()), [
      (0, 'docs/'),
      (0, 'src/'),
      (1, 'lib/'),
      (1, 'inner@'),
      (1, 'main.dart'),
      (0, 'gone@'),
      (0, 'README.md'),
      (0, 'shared@'),
    ]);

    // Opening follows the link: it browses the directory it points to.
    await workspace.open('$root/shared');
    expect(names(workspace.rows()), [(0, 'keep.txt')]);
    await workspace.openDir(root);

    await workspace.delete('$root/shared');
    expect(FileSystemEntity.typeSync('$root/shared', followLinks: false), FileSystemEntityType.notFound);
    expect(File('${outside.path}/keep.txt').readAsStringSync(), 'keep\n');
    await workspace.delete('$root/src');
    expect(Directory('$root/src').existsSync(), isFalse);
    expect(File('${outside.path}/keep.txt').readAsStringSync(), 'keep\n');
    await workspace.delete('$root/gone');
    expect(FileSystemEntity.typeSync('$root/gone', followLinks: false), FileSystemEntityType.notFound);
    expect(names(workspace.rows()), [(0, 'docs/'), (0, 'README.md')]);
  });

  test('git status and diff of the browsed repository', () async {
    await git(['init', '-q']);
    await git(['add', 'README.md', 'src/main.dart']);
    await git(['commit', '-q', '-m', 'init']);
    File('$root/README.md').writeAsStringSync('# Demo\nline two\nline three\n');

    await workspace.follow(root);
    await workspace.refreshGit();
    final status = workspace.git!;
    expect(status.changeOf('$root/README.md'), GitChange.modified);
    expect(status.changeOf('$root/src/lib/a.dart'), GitChange.untracked);
    expect(status.changeOf('$root/src/main.dart'), isNull);
    expect(status.dirty, contains('$root/src'));

    final diff = await workspace.diff('$root/README.md');
    expect(diff, contains('+line three'));
    expect(await workspace.diff('$root/src/main.dart'), isEmpty);

    // From a subdirectory the repository root is still the browsed path's ancestor, not git's real path.
    await workspace.openDir('$root/docs');
    await workspace.refreshGit();
    expect(workspace.git?.root, root);
    await workspace.openDir(Directory.systemTemp.path);
    await workspace.refreshGit();
    expect(workspace.git, isNull);
  });

  test('git gets paths inside an sh script, never on the command line the login shell parses', () async {
    // fish reads \' inside single quotes as an escaped quote: sh quoting on its command line can be broken out of.
    const name = r"it\'s;touch pwned;#";
    File('$root/$name/notes.txt').createSync(recursive: true);
    File('$root/$name/notes.txt').writeAsStringSync('one\n');
    await git(['init', '-q']);
    await git(['add', '.']);
    await git(['commit', '-q', '-m', 'init']);
    File('$root/$name/notes.txt').writeAsStringSync('two\n');
    final recording = _RecordingLink(link);
    final browser = FileWorkspace()..connect = () async => (recording, probe);
    addTearDown(browser.dispose);

    await browser.openDir('$root/$name');
    await browser.refreshGit();
    expect(browser.git?.changeOf('$root/$name/notes.txt'), GitChange.modified);
    expect(await browser.diff('$root/$name/notes.txt'), contains('+two'));
    expect(recording.commands, isNotEmpty);
    expect(recording.commands, everyElement('sh -s'));
  });

  test('file access is opened once per link, however many operations start at the same time', () async {
    final first = _RecordingLink(link);
    HostLink current = first;
    final browser = FileWorkspace()..connect = () async => (current, probe);
    addTearDown(browser.dispose);
    await Future.wait([browser.follow(root), browser.open('$root/README.md')]);
    await browser.openDir(root);
    await browser.toggle('$root/src');
    await browser.toggle('$root/docs');
    expect(first.filesOpened, 1);

    // A reconnect: the next refresh lists three directories over one new channel.
    final second = _RecordingLink(link);
    current = second;
    await browser.refresh();
    expect(second.filesOpened, 1);
  });

  test('a transcript file is read line by line from an offset, and again from 0 after a rewrite', () async {
    final files = await link.files();
    final path = '$root/agent.jsonl';
    final header = jsonEncode({'type': 'session', 'id': 's'});
    final first = jsonEncode({'type': 'message', 'id': 'a', 'parentId': null});
    File(path).writeAsStringSync('$header\n$first\n{"type":"mess');

    final chunk = await readTranscriptChunk(files, path, 0);
    expect(chunk.entries.map((entry) => entry['id']), ['s', 'a']);
    expect(chunk.nextByte, utf8.encode('$header\n$first\n').length);
    expect(chunk.reset, isFalse);

    File(path).writeAsStringSync('age","id":"b","parentId":"a"}\n', mode: FileMode.append);
    final next = await readTranscriptChunk(files, path, chunk.nextByte);
    expect(next.entries.map((entry) => entry['id']), ['b']);

    File(path).writeAsStringSync('$first\n');
    final rewritten = await readTranscriptChunk(files, path, next.nextByte);
    expect(rewritten.reset, isTrue);
    expect(rewritten.entries.map((entry) => entry['id']), ['a']);

    final missing = await readTranscriptChunk(files, '$root/none.jsonl', 7);
    expect(missing.nextByte, 7);
    expect(missing.entries, isEmpty);
  });
}

/// Delegates to a real link and records every command it is asked to run and every file access it opens.
final class _RecordingLink implements HostLink {
  _RecordingLink(this._inner);

  final HostLink _inner;
  final commands = <String>[];
  var filesOpened = 0;

  @override
  String get label => _inner.label;

  @override
  Future<HostProcess> exec(String command, {PtyRequest? pty}) {
    commands.add(command);
    return _inner.exec(command, pty: pty);
  }

  @override
  Future<HostFiles> files() {
    filesOpened++;
    return _inner.files();
  }

  @override
  Future<HostSocket> connect(String host, int port) => _inner.connect(host, port);

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> close() => _inner.close();
}

/// A file that reports size 0 and never ends, like `/dev/zero` or a `/proc` file over SFTP: a read without a length
/// goes on until the data runs out; here that is 3 MiB. Records the lengths asked for.
final class _EndlessFiles implements HostFiles {
  final lengths = <int?>[];

  @override
  Future<HostFileStat?> stat(String path, {bool followLinks = true}) async =>
      const HostFileStat(size: 0, isDirectory: false);

  @override
  Future<Uint8List> read(String path, {int offset = 0, int? length}) async {
    lengths.add(length);
    return Uint8List(length ?? 3 << 20)..fillRange(0, length ?? 3 << 20, 0x61);
  }

  @override
  Future<List<HostDirEntry>> list(String path) => throw UnimplementedError();

  @override
  Future<void> write(String path, List<int> bytes, {bool append = false, int? mode}) => throw UnimplementedError();

  @override
  Future<void> mkdir(String path, {int? mode}) => throw UnimplementedError();

  @override
  Future<void> remove(String path) => throw UnimplementedError();

  @override
  Future<void> removeDir(String path) => throw UnimplementedError();

  @override
  Future<void> rename(String from, String to) => throw UnimplementedError();

  @override
  Future<String> home() => throw UnimplementedError();

  @override
  Future<void> close() async {}
}
