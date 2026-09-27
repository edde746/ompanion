import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/sessions/message_mentions.dart';
import 'package:ompanion/sessions/prompt_attachments.dart';

/// Text parts as they are, mentions as `<path>`, tagged models as `[agent name]`.
List<String> _split(String message) => [
  for (final part in splitMentions(message))
    switch (part) {
      MessageText(:final source) => source,
      MessageMention(:final path) => '<$path>',
      MessageModel(:final agent, :final name) => '[$agent $name]',
    },
];

void main() {
  test('the parts of a message join back to the exact message', () {
    const message = 'Review @"/tmp/a b.txt", (@src/x.ts) and local://paste-2.md.\n@\'it"s.md\' done';
    expect(splitMentions(message).map((part) => part.source).join(), message);
  });

  test('a model tag omp wrote is one part with its pseudonym and name; mentions around it still count', () {
    const message = 'Have <model agent="m1" name="Fake Think"/> review @src/a.ts, then <model agent="m12" name=""/>.';
    expect(_split(message), ['Have ', '[m1 Fake Think]', ' review ', '<src/a.ts>', ', then ', '[m12 ]', '.']);
    expect(splitMentions(message).map((part) => part.source).join(), message);
  });

  test('text that only resembles a model tag stays text, as omp leaves it', () {
    for (final message in ['<model agent="x1" name="A"/>', '<model agent="m1" name="A">', '^fake/fake-1 please']) {
      expect(_split(message), [message], reason: message);
    }
  });

  test('the mentions the app writes for attachments come back as their paths', () {
    const paths = ['/Users/x/.omp/agent/sessions/-proj/2026-01/local/meeting notes.txt', '/tmp/say "hi".md'];
    final message = assembleMessage('Please review these.', [for (final path in paths) fileMention(path)!]);
    expect(_split(message), ['Please review these. ', '<${paths[0]}>', ' ', '<${paths[1]}>']);
  });

  test('an unquoted mention loses the punctuation around it as omp strips it', () {
    expect(_split('see @src/foo.ts, then (@lib/a.dart) and "@b.md"!'), [
      'see ',
      '<src/foo.ts>',
      ', then (',
      '<lib/a.dart>',
      ') and "',
      '<b.md>',
      '"!',
    ]);
    expect(_split('@(`x`)'), ['<x>', '`)']);
  });

  test('a quoted mention keeps its punctuation and loses only surrounding whitespace', () {
    expect(_split('@" notes (v2).txt " ok'), ['<notes (v2).txt>', ' ok']);
  });

  test('omp reads no mention inside a word, in an empty or blank quote, or made only of punctuation', () {
    for (final message in ['mail me at me@example.com', 'x@"a.md"', '@"" then', '@" " then', 'wow @!!', '@ alone']) {
      expect(splitMentions(message).whereType<MessageMention>(), isEmpty, reason: message);
    }
  });

  test('a mention ends at the next @, which starts a mention only after a boundary', () {
    expect(_split('@a.md@b.md @c.md'), ['<a.md>', '@b.md ', '<c.md>']);
  });

  test('a local:// reference is a mention, cut like an unquoted one', () {
    expect(_split('Log: local://paste-3.md.'), ['Log: ', '<local://paste-3.md>', '.']);
    expect(_split('@local://paste-1.md'), ['<local://paste-1.md>']);
    expect(_split('not a local:// thing, nor xlocal://y'), ['not a local:// thing, nor xlocal://y']);
  });

  test("a mention's name is its path's last segment; a local:// one is no machine path", () {
    final [file, folder, windows, paste] = splitMentions(
      r'@"/tmp/meeting notes.txt" @src/widgets/ @"C:\Users\x\a b.log" local://paste-1.md',
    ).whereType<MessageMention>().toList();
    expect(
      [file.name, folder.name, windows.name, paste.name],
      ['meeting notes.txt', 'widgets', 'a b.log', 'paste-1.md'],
    );
    expect([file.folder, folder.folder, paste.folder], [false, true, false]);
    expect([file.url, windows.url, paste.url], [false, false, true]);
  });
}
