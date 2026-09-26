import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/files/file_document.dart';
import 'package:ompanion/files/file_language.dart';
import 'package:ompanion/files/file_paths.dart';
import 'package:ompanion/files/git_status.dart';

void main() {
  group('paths', () {
    test('normalize collapses slashes, dots and parents; drive roots keep their slash', () {
      expect(normalizePath('/a//b/./c/../d/'), '/a/b/d');
      expect(normalizePath('/../..'), '/');
      expect(normalizePath('/C:'), '/C:/');
      expect(normalizePath('/C:/Users/../'), '/C:/');
      expect(normalizePath('a/b/..'), 'a');
      expect(normalizePath(''), '.');
    });

    test('parent and base name', () {
      expect(parentPath('/home/omp/project'), '/home/omp');
      expect(parentPath('/home'), '/');
      expect(parentPath('/'), '/');
      expect(parentPath('/C:/Users'), '/C:/');
      expect(parentPath('/C:/'), '/');
      expect(baseName('/home/omp/README.md'), 'README.md');
      expect(baseName('/C:/'), 'C:');
      expect(baseName('/'), '/');
      expect(joinPath('/', 'etc'), '/etc');
      expect(joinPath('/C:/', 'Users'), '/C:/Users');
      expect(joinPath('/home', 'omp'), '/home/omp');
    });

    test('breadcrumbs lead from the root to the directory; a drive is one crumb', () {
      expect(breadcrumbs('/home/omp/demo-project'), const [
        Crumb('/', '/'),
        Crumb('home', '/home'),
        Crumb('omp', '/home/omp'),
        Crumb('demo-project', '/home/omp/demo-project'),
      ]);
      expect(breadcrumbs('/C:/Users/x'), const [
        Crumb('/', '/'),
        Crumb('C:', '/C:/'),
        Crumb('Users', '/C:/Users'),
        Crumb('x', '/C:/Users/x'),
      ]);
      expect(breadcrumbs('/'), const [Crumb('/', '/')]);
    });

    test('relative paths only inside the root', () {
      expect(relativePath('/home/omp', '/home/omp/a/b'), 'a/b');
      expect(relativePath('/home/omp', '/home/omp'), '.');
      expect(relativePath('/home/omp', '/home/omphalos'), isNull);
      expect(relativePath('/', '/etc'), 'etc');
    });

    test('extensions and names', () {
      expect(extensionOf('main.DART'), 'dart');
      expect(extensionOf('.bashrc'), '');
      expect(extensionOf('Makefile'), '');
      expect(extensionOf('archive.tar.gz'), 'gz');
      expect(checkName('ok.txt'), isNull);
      expect(checkName('  '), NameProblem.empty);
      expect(checkName('..'), NameProblem.reserved);
      expect(checkName('a/b'), NameProblem.separator);
      expect(checkName(r'a\b'), NameProblem.separator);
    });

    test('isRootPath', () {
      expect(isRootPath('/'), isTrue);
      expect(isRootPath('/D:/'), isTrue);
      expect(isRootPath('/D:/x'), isFalse);
    });
  });

  group('git status', () {
    const root = '/repo';
    final porcelain = [
      ' M lib/main.dart',
      'M  README.md',
      'A  lib/new.dart',
      ' D old.txt',
      'R  lib/renamed.dart',
      'lib/original.dart',
      '?? notes/',
      '?? scratch.txt',
      'UU conflict.dart',
      'AM added_then_edited.dart',
      '!! build/',
      '',
    ].join('\u0000');
    final status = GitStatus.parse(root, porcelain);

    test('each porcelain record becomes one change; a rename skips its source path', () {
      expect(status.files, {
        '/repo/lib/main.dart': GitChange.modified,
        '/repo/README.md': GitChange.modified,
        '/repo/lib/new.dart': GitChange.added,
        '/repo/old.txt': GitChange.deleted,
        '/repo/lib/renamed.dart': GitChange.renamed,
        '/repo/notes': GitChange.untracked,
        '/repo/scratch.txt': GitChange.untracked,
        '/repo/conflict.dart': GitChange.conflicted,
        '/repo/added_then_edited.dart': GitChange.added,
        '/repo/build': GitChange.ignored,
      });
    });

    test('directories holding a change are dirty, up to the repository root; ignored ones are not', () {
      expect(status.dirty, {'/repo', '/repo/lib'});
    });

    test('a file inside an untracked or ignored directory takes its state', () {
      expect(status.changeOf('/repo/notes/today.md'), GitChange.untracked);
      expect(status.changeOf('/repo/build/out/app'), GitChange.ignored);
      expect(status.changeOf('/repo/lib/clean.dart'), isNull);
      expect(status.changeOf('/elsewhere/file'), isNull);
    });
  });

  group('file text', () {
    test('UTF-8 text is editable', () {
      final (text, reason) = decodeFileText(utf8.encode('héllo\r\nwörld\n'), truncated: false);
      expect((text, reason), ('héllo\r\nwörld\n', null));
    });

    test('a NUL byte early on marks a binary file', () {
      final (_, reason) = decodeFileText([0x89, 0x50, 0x4e, 0x47, 0x00, 0x01], truncated: false);
      expect(reason, ReadOnlyReason.binary);
    });

    test('bytes that are not UTF-8 stay read-only instead of being rewritten', () {
      final (text, reason) = decodeFileText([0x63, 0x61, 0x66, 0xe9], truncated: false);
      expect(reason, ReadOnlyReason.notUtf8);
      expect(text, 'caf\u{fffd}');
    });

    test('a truncated prefix is read-only even when it cuts a character in half', () {
      final bytes = utf8.encode('ab€');
      final (text, reason) = decodeFileText(bytes.sublist(0, bytes.length - 1), truncated: true);
      expect(reason, ReadOnlyReason.tooLarge);
      expect(text, startsWith('ab'));
    });
  });

  test('languages from file names', () {
    expect(languageFor('main.dart'), 'dart');
    expect(languageFor('App.tsx'), 'typescript');
    expect(languageFor('setup.py'), 'python');
    expect(languageFor('config.yml'), 'yaml');
    expect(languageFor('Dockerfile'), 'dockerfile');
    expect(languageFor('Makefile'), 'makefile');
    expect(languageFor('.zshrc'), 'bash');
    expect(languageFor('lib.rs'), 'rust');
    expect(languageFor('README.md'), 'markdown');
    expect(languageFor('data.unknownext'), isNull);
    expect(languageFor('LICENSE'), isNull);
    expect(modeFor(languageFor('main.go')!), isNotNull);
  });
}
