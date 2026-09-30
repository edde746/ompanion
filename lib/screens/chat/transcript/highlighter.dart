import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:re_highlight/languages/all.dart';
import 'package:re_highlight/re_highlight.dart';

import '../../../app/palette.dart';
import '../../../app/theme.dart';
import '../../../utils/app_logger.dart';

/// Scope runs of highlighted code: run `i` covers `[ends[i - 1], ends[i])` of the code (from 0 for the first run)
/// and carries the innermost highlight.js scope, or null for plain text.
final class HighlightRuns {
  const HighlightRuns(this.ends, this.scopes);

  final Int32List ends;
  final List<String?> scopes;
}

/// Fence infos and file names highlight.js does not know under that name.
const _aliases = {
  'zsh': 'bash',
  'shell': 'bash',
  'jsonc': 'json',
  'json5': 'json',
  'jsonl': 'json',
  'vue': 'xml',
  'svelte': 'xml',
  'htm': 'xml',
  'dockerfile': 'dockerfile',
  'makefile': 'makefile',
  'gnumakefile': 'makefile',
};

/// The highlight.js language for a fence info string (`dart`, `ts`, `sh`, …); null for plain text.
String? languageForFence(String? info) {
  final name = info?.trim().toLowerCase() ?? '';
  if (name.isEmpty || name == 'text' || name == 'plain' || name == 'plaintext' || name == 'txt') return null;
  return _aliases[name] ?? name;
}

/// The highlight.js language for a file path, from its extension or well-known name; null when unknown.
String? languageForPath(String path) {
  final name = path.split(RegExp(r'[/\\]')).last.toLowerCase();
  if (_aliases[name] case final language?) return language;
  final dot = name.lastIndexOf('.');
  if (dot <= 0 || dot == name.length - 1) return null;
  return languageForFence(name.substring(dot + 1));
}

/// Syntax highlighting for the transcript: one long-lived worker isolate runs re_highlight (a regex engine whose cost
/// grows with the code), and results are cached by language and code, so a code block that scrolls back into view or
/// rebuilds finds its colours at once.
final class CodeHighlighter {
  CodeHighlighter._();

  static final instance = CodeHighlighter._();

  /// Cached results, least recently used first; a null value means the language is unknown.
  final _cache = <String, HighlightRuns?>{};
  var _cachedChars = 0;
  static const _maxCachedChars = 4 << 20;
  static const _maxCachedEntries = 512;

  final _pending = <int, (String, Completer<HighlightRuns?>)>{};
  final _inFlight = <String, Future<HighlightRuns?>>{};
  var _nextId = 0;
  Future<SendPort>? _worker;

  static String _key(String language, String code) => '$language\u0000$code';

  /// The cached result for [code] in [language]; null when absent or unknown. Use [isCached] to tell them apart.
  HighlightRuns? cached(String language, String code) {
    final key = _key(language, code);
    if (!_cache.containsKey(key)) return null;
    // Most recently used last; a null (unknown language) entry moves too, so its size stays counted.
    final runs = _cache.remove(key);
    _cache[key] = runs;
    return runs;
  }

  bool isCached(String language, String code) => _cache.containsKey(_key(language, code));

  /// Highlights [code] in [language] on the worker; completes with null when the language is unknown.
  Future<HighlightRuns?> highlight(String language, String code) {
    final key = _key(language, code);
    if (_cache.containsKey(key)) return Future.value(cached(language, code));
    // A block body: `remove` returns this very future, and `whenComplete` would wait for it.
    return _inFlight[key] ??= _request(key, language, code).whenComplete(() {
      _inFlight.remove(key);
    });
  }

  Future<HighlightRuns?> _request(String key, String language, String code) async {
    final worker = await (_worker ??= _spawn());
    final id = _nextId++;
    final completer = Completer<HighlightRuns?>();
    _pending[id] = (key, completer);
    worker.send((id, language, code));
    return completer.future;
  }

  Future<SendPort> _spawn() async {
    final replies = ReceivePort('transcript highlighter');
    final ready = Completer<SendPort>();
    replies.listen((message) {
      switch (message) {
        case final SendPort port:
          ready.complete(port);
        case (final int id, final HighlightRuns? runs, final String? error):
          final (key, completer) = _pending.remove(id)!;
          if (error != null) appLogger.w('Syntax highlighting failed: $error');
          _store(key, runs);
          completer.complete(runs);
      }
    });
    await Isolate.spawn(_highlightWorker, replies.sendPort, debugName: 'transcript highlighter');
    return ready.future;
  }

  void _store(String key, HighlightRuns? runs) {
    _cache[key] = runs;
    _cachedChars += key.length;
    while (_cache.length > _maxCachedEntries || _cachedChars > _maxCachedChars) {
      final oldest = _cache.keys.first;
      _cache.remove(oldest);
      _cachedChars -= oldest.length;
    }
  }
}

void _highlightWorker(SendPort replies) {
  final requests = ReceivePort('transcript highlighter requests');
  replies.send(requests.sendPort);
  final engine = Highlight()..registerLanguages(builtinAllLanguages);
  requests.listen((message) {
    final (int id, String language, String code) = message as (int, String, String);
    if (engine.getLanguage(language) == null) {
      replies.send((id, null, null));
      return;
    }
    try {
      final renderer = _RunRenderer();
      engine.highlight(code: code, language: language).render(renderer);
      replies.send((id, HighlightRuns(Int32List.fromList(renderer.ends), renderer.scopes), null));
    } on Object catch (error) {
      // A grammar that throws on some input must not take the worker down: the block stays plain and the error is
      // logged on the UI side.
      replies.send((id, null, '$language: $error'));
    }
  });
}

final class _RunRenderer implements HighlightRenderer {
  final ends = <int>[];
  final scopes = <String?>[];
  final _stack = <String?>[];
  var _position = 0;

  @override
  void addText(String text) {
    _position += text.length;
    final scope = _stack.isEmpty ? null : _stack.last;
    if (scopes.isNotEmpty && scopes.last == scope) {
      ends[ends.length - 1] = _position;
    } else {
      ends.add(_position);
      scopes.add(scope);
    }
  }

  @override
  void openNode(DataNode node) => _stack.add(node.scope ?? (_stack.isEmpty ? null : _stack.last));

  @override
  void closeNode(DataNode node) => _stack.removeLast();
}

/// highlight.js scopes by the syntax token that colours them: Atom One's groups.
const _syntaxScopes = {
  ThemeToken.comment: ['comment', 'quote'],
  ThemeToken.keyword: ['doctag', 'keyword', 'formula'],
  ThemeToken.tag: ['section', 'name', 'selector-tag', 'deletion', 'subst'],
  ThemeToken.literal: ['literal'],
  ThemeToken.string: ['string', 'regexp', 'addition', 'attribute', 'meta-string'],
  ThemeToken.number: [
    'attr',
    'variable',
    'template-variable',
    'type',
    'selector-class',
    'selector-attr',
    'selector-pseudo',
    'number',
  ],
  ThemeToken.title: ['symbol', 'bullet', 'link', 'meta', 'selector-id', 'title'],
  ThemeToken.builtIn: ['built_in', 'title.class_', 'class-title'],
};

final _highlightThemes = Expando<Map<String, TextStyle>>();

/// highlight.js styles from the theme's syntax tokens, by scope.
Map<String, TextStyle> highlightTheme(AppColors colors) => _highlightThemes[colors] ??= {
  for (final MapEntry(key: token, value: scopes) in _syntaxScopes.entries)
    for (final scope in scopes)
      scope: TextStyle(color: colors[token], fontStyle: token == ThemeToken.comment ? FontStyle.italic : null),
  'emphasis': const TextStyle(fontStyle: FontStyle.italic),
  'strong': const TextStyle(fontWeight: FontWeight.bold),
};

/// [code] as spans coloured by [runs] under [theme]; a scope is looked up whole, then by its first dotted part.
List<TextSpan> highlightedSpans(String code, HighlightRuns runs, Map<String, TextStyle> theme) {
  final spans = <TextSpan>[];
  var start = 0;
  for (var i = 0; i < runs.ends.length; i++) {
    final end = runs.ends[i];
    if (end > code.length) break;
    final scope = runs.scopes[i];
    final style = scope == null ? null : theme[scope] ?? theme[scope.split('.').first];
    spans.add(
      TextSpan(
        text: code.substring(start, end),
        style: style?.copyWith(backgroundColor: Colors.transparent),
      ),
    );
    start = end;
  }
  if (start < code.length) spans.add(TextSpan(text: code.substring(start)));
  return spans;
}
