import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ompanion/i18n/strings.g.dart';

const _pluralForms = {'zero', 'one', 'two', 'few', 'many', 'other'};
final _placeholder = RegExp(r'\$\{(\w+)\}|\$(\w+)');

/// Each string's path with the placeholders it uses. A plural is one string: a form may leave out the count
/// (German `einen Schlüssel` for English `the 1 key`), so its forms pool their placeholders.
Map<String, Set<String>> _strings(Object? node, [String path = '']) => switch (node) {
  Map<String, Object?>(:final keys) when keys.isNotEmpty && keys.every(_pluralForms.contains) => {
    path: {for (final form in node.values) ..._placeholders(form as String)},
  },
  Map<String, Object?>() => {for (final MapEntry(:key, :value) in node.entries) ..._strings(value, '$path.$key')},
  List<Object?>() => {for (final (index, value) in node.indexed) ..._strings(value, '$path[$index]')},
  final String text => {path: _placeholders(text)},
  _ => throw FormatException('$path: not a string', node),
};

Set<String> _placeholders(String text) => {for (final match in _placeholder.allMatches(text)) match[1] ?? match[2]!};

Map<String, Object?> _load(AppLocale locale) =>
    jsonDecode(File('lib/i18n/${locale.languageCode}.i18n.json').readAsStringSync()) as Map<String, Object?>;

void main() {
  final base = _strings(_load(AppLocale.en));

  // slang falls back to English for a missing string, so nothing else notices one.
  for (final locale in AppLocale.values.where((locale) => locale != AppLocale.en)) {
    test('${locale.languageCode} has every English string with the same placeholders', () {
      final strings = _strings(_load(locale));
      expect(strings.keys.toSet().difference(base.keys.toSet()), isEmpty, reason: 'strings English does not have');
      expect(base.keys.toSet().difference(strings.keys.toSet()), isEmpty, reason: 'strings missing');
      for (final MapEntry(key: path, value: placeholders) in base.entries) {
        expect(strings[path], placeholders, reason: path);
      }
    });
  }
}
