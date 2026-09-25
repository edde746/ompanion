import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

/// One omp settings file (`config.yml`) as nested plain values. Setting paths address it by their dotted
/// segments: `startup.checkUpdate` is `startup: {checkUpdate: …}`.
final class ConfigLayer {
  const ConfigLayer(this.root);

  /// Parses a settings file. An empty file, or one holding only comments, is an empty layer. Throws a
  /// [FormatException] with the position only: the file may hold credentials, so no source text is quoted.
  factory ConfigLayer.parse(String text) {
    final Object? document;
    try {
      document = loadYaml(text);
    } on YamlException catch (error) {
      throw _invalid(error);
    }
    return switch (_plain(document)) {
      null => const ConfigLayer({}),
      final Map<String, Object?> map => ConfigLayer(map),
      _ => throw const FormatException('the settings file does not hold a map'),
    };
  }

  final Map<String, Object?> root;

  /// The value at [path], or null when the file does not hold it. A key present with an empty value is a
  /// hit whose value is null.
  ({Object? value})? lookup(List<String> path) {
    Object? node = root;
    for (final segment in path) {
      if (node is! Map<String, Object?> || !node.containsKey(segment)) return null;
      node = node[segment];
    }
    return (value: node);
  }
}

Object? _plain(Object? node) => switch (node) {
  final YamlMap map => {for (final MapEntry(:key, :value) in map.entries) '$key': _plain(value)},
  final YamlList list => [for (final item in list) _plain(item)],
  final YamlScalar scalar => scalar.value,
  _ => node,
};

/// [source] with [path] set to [value], comments and layout kept. Missing parent maps are created; a parent
/// holding a scalar is a [FormatException].
String setConfigValue(String source, List<String> path, Object? value) {
  if (path.isEmpty) throw ArgumentError.value(path, 'path', 'empty');
  return _edit(source, path, (editor) {
    final root = editor.parseAt(const []);
    if (root is! YamlMap) {
      if (root.value != null) throw const FormatException('the settings file does not hold a map');
      // yaml_edit replaces the root's span, which in a file of only comments covers the comments.
      if (_holdsNoNode(root)) return _insertBlock(source, root.span.end.offset, _nest(path, value));
      editor.update(const [], _nest(path, value));
      return editor.toString();
    }
    var node = root;
    var depth = 0;
    while (depth < path.length - 1) {
      final child = node.nodes[path[depth]];
      if (child is YamlMap) {
        node = child;
        depth++;
        continue;
      }
      if (child != null && child.value != null) {
        throw FormatException('${path.take(depth + 1).join('.')} holds a value, not a map');
      }
      break;
    }
    editor.update(path.take(depth + 1), _nest(path.sublist(depth + 1), value));
    return editor.toString();
  });
}

/// [source] without [path]; parent maps left empty by the removal are removed too. Unchanged when the file
/// does not hold [path].
String removeConfigValue(String source, List<String> path) {
  if (path.isEmpty) throw ArgumentError.value(path, 'path', 'empty');
  return _edit(source, path, (editor) {
    if (!_holds(editor, path)) return source;
    editor.remove(path);
    for (var depth = path.length - 1; depth > 0; depth--) {
      final parent = path.sublist(0, depth);
      final node = editor.parseAt(parent);
      if (node is! YamlMap || node.isNotEmpty) break;
      editor.remove(parent);
    }
    return editor.toString();
  });
}

/// Runs [edit] on a [YamlEditor] of [source]. yaml_edit's errors quote the file, which may hold credentials, so
/// they become [FormatException]s that name a position or [path], never the text.
String _edit(String source, List<String> path, String Function(YamlEditor editor) edit) {
  try {
    return edit(YamlEditor(source));
  } on YamlException catch (error) {
    throw _invalid(error);
  } on AliasException {
    throw FormatException('${path.join('.')} is reached through a YAML alias (& or *), which the app does not edit');
  } on Error catch (error) {
    // yaml_edit parses each edit's output again and throws an AssertionError quoting the file before and after
    // when it differs; its ArgumentErrors print the nodes or the value involved.
    if (error is! AssertionError && error is! ArgumentError) rethrow;
    throw FormatException('could not write ${path.join('.')} into the settings file');
  }
}

FormatException _invalid(YamlException error) {
  final start = error.span?.start;
  final where = start == null ? '' : ' at line ${start.line + 1}, column ${start.column + 1}';
  return FormatException('not valid YAML$where: ${error.message}');
}

/// A document of only comments and blank lines, as opposed to an explicit null (`~`, `null`).
bool _holdsNoNode(YamlNode root) => root.span.text.replaceAll(RegExp('#.*'), '').trim().isEmpty;

/// [source] with the block YAML of [value] inserted at [offset], on lines of its own.
String _insertBlock(String source, int offset, Object? value) {
  final newline = source.contains('\r\n') ? '\r\n' : '\n';
  final block = (YamlEditor('')..update(const [], value)).toString().replaceAll('\n', newline);
  final before = source.substring(0, offset);
  final separator = before.isEmpty || before.endsWith('\n') ? '' : newline;
  return '$before$separator$block$newline${source.substring(offset)}';
}

bool _holds(YamlEditor editor, List<String> path) {
  YamlNode node = editor.parseAt(const []);
  for (final segment in path) {
    if (node is! YamlMap) return false;
    final child = node.nodes[segment];
    if (child == null) return false;
    node = child;
  }
  return true;
}

Object? _nest(List<String> rest, Object? value) =>
    rest.isEmpty ? _quoted(value) : {rest.first: _nest(rest.sublist(1), value)};

/// YAML 1.1 readers take these plain words as booleans or null; omp's parser does not, but quoting keeps the
/// file unambiguous for every reader (omp's own docs quote `"off"`).
final _ambiguousWord = RegExp(r'^(?:y|Y|yes|Yes|YES|n|N|no|No|NO|on|On|ON|off|Off|OFF|~)$');

Object? _quoted(Object? value) => switch (value) {
  final String text when _ambiguousWord.hasMatch(text) => YamlScalar.wrap(text, style: ScalarStyle.DOUBLE_QUOTED),
  final Map<String, Object?> map => {for (final MapEntry(:key, :value) in map.entries) key: _quoted(value)},
  final List<Object?> list => [for (final item in list) _quoted(item)],
  _ => value,
};
