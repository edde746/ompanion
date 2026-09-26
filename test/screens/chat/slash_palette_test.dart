import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/screens/chat/slash_palette.dart';
import 'package:omp_core/store.dart';

const _commands = [
  SlashCommand(name: 'session', source: 'builtin'),
  SlashCommand(name: 'compact', aliases: ['squash'], source: 'builtin'),
  SlashCommand(name: 'copy', source: 'builtin'),
  SlashCommand(name: 'model', source: 'builtin'),
  SlashCommand(name: 'ompx', source: 'extension'),
  SlashCommand(name: 'pause', source: 'extension'),
];

List<String> _names(String query) => [for (final command in filterCommands(_commands, query)) command.name];

void main() {
  group('paletteQuery', () {
    test('is the name typed after the slash', () {
      expect(paletteQuery('/'), '');
      expect(paletteQuery('/com'), 'com');
    });

    test('closes at the first space, for arguments', () {
      expect(paletteQuery('/compact now'), isNull);
    });

    test('is absent for paths and plain text', () {
      expect(paletteQuery('/usr/bin'), isNull);
      expect(paletteQuery('hello /com'), isNull);
    });
  });

  group('filterCommands', () {
    test('an empty query lists every command in session order', () {
      expect(_names(''), [for (final command in _commands) command.name]);
    });

    test('ranks name prefix, then alias prefix, then substring, then letters in order', () {
      expect(_names('co'), ['compact', 'copy']);
      expect(_names('sq'), ['compact']);
      expect(_names('ss'), ['session']);
      expect(_names('mdl'), ['model']);
    });

    test('orders every match by rank, not by session order', () {
      expect(_names('s'), ['session', 'compact', 'pause']);
    });

    test('is case-insensitive', () {
      expect(_names('PAU'), ['pause']);
    });

    test('drops commands that do not match', () {
      expect(_names('xyz'), isEmpty);
    });
  });
}
